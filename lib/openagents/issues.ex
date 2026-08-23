defmodule OpenAgents.Issues do
  @moduledoc "Repository-scoped issues, comments, labels, milestones, and assignees."

  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Analytics
  alias OpenAgents.Issues.{Comment, Issue, IssueDependency}
  alias OpenAgents.Labels
  alias OpenAgents.Labels.Label
  alias OpenAgents.Milestones
  alias OpenAgents.Milestones.Milestone
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @issues_per_page 25
  @maximum_page 10_000

  @doc "How many issues one index page shows."
  def per_page, do: @issues_per_page

  def list_issues(%Repository{id: repository_id}, opts \\ []) when is_list(opts) do
    repository_id
    |> issue_query(opts)
    |> order_by([issue], desc: issue.inserted_at, desc: issue.id)
    |> Repo.all()
  end

  @doc """
  One page of the filtered issue list, with the unpaginated total.

  Supported options: `:state`, `:label`, `:assignee`, `:milestone`, `:q`,
  `:blocked`, and `:page`. Filters compose; counts and pages always agree
  because they read the same query.
  """
  def list_issues_page(%Repository{} = repository, opts) when is_list(opts) do
    page = max(parse_page(opts[:page]), 1)
    query = issue_query(repository.id, opts)

    total = Repo.aggregate(query, :count)

    issues =
      query
      |> order_by([issue], desc: issue.inserted_at, desc: issue.id)
      |> limit(@issues_per_page)
      |> offset(^((page - 1) * @issues_per_page))
      |> Repo.all()

    {issues, total}
  end

  def count_issues(%Repository{} = repository, opts) when is_list(opts),
    do: repository.id |> issue_query(opts) |> Repo.aggregate(:count)

  def parse_page(page) when is_integer(page), do: page |> max(1) |> min(@maximum_page)

  def parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} -> parse_page(number)
      :error -> 1
      {_number, _trailing} -> 1
    end
  end

  def parse_page(_page), do: 1

  @doc """
  One page of the issues `user` can read, across every repository, with the
  unpaginated total.

  The workspace-wide counterpart to `list_issues_page/2`. Where that one is
  handed a repository the caller has already authorized, this one authorizes
  as it reads: the issue table is joined to `Repositories.readable_by/2`, the
  single predicate every repository surface composes, so an issue in a private
  repository the reader has no membership in cannot reach the query's result
  no matter what the options say.

  Supported options: `:state`, `:assignee`, `:author`, `:q`, and `:page`.
  Rows come back with their repository preloaded, because a cross-repository
  list has to say which repository each row belongs to.
  """
  def list_visible_issues_page(%User{} = user, opts \\ []) when is_list(opts) do
    page = max(parse_page(opts[:page]), 1)
    query = visible_issue_query(user, opts)

    total = Repo.aggregate(query, :count)

    issues =
      query
      |> order_by([issue], desc: issue.inserted_at, desc: issue.id)
      |> limit(@issues_per_page)
      |> offset(^((page - 1) * @issues_per_page))
      |> Repo.all()
      |> Repo.preload(repository: :namespace)

    {issues, total}
  end

  @doc "How many issues `user` can read across every repository, filtered."
  def count_visible_issues(%User{} = user, opts \\ []) when is_list(opts),
    do: user |> visible_issue_query(opts) |> Repo.aggregate(:count)

  # The readable-repository set arrives as a subquery rather than as extra
  # joins on this query, so the membership left join keeps its own bindings and
  # the filter chain below still sees the issue as binding zero.
  defp visible_issue_query(user, opts) do
    readable = from(repository in Repositories.readable_by(Repository, user), select: repository)

    from(issue in Issue,
      as: :issue,
      join: repository in subquery(readable),
      on: repository.id == issue.repository_id
    )
    |> apply_issue_filters(opts)
    |> maybe_filter_author(Keyword.get(opts, :author))
  end

  # Every list surface shares one filter chain so a page, a count, and an
  # unpaginated read can never disagree about what matches.
  defp issue_query(repository_id, opts) do
    from(issue in Issue, as: :issue)
    |> where([issue], issue.repository_id == ^repository_id)
    |> apply_issue_filters(opts)
  end

  defp apply_issue_filters(query, opts) do
    query
    |> maybe_filter_state(Keyword.get(opts, :state, "open"))
    |> maybe_filter_label(Keyword.get(opts, :label))
    |> maybe_filter_assignee(Keyword.get(opts, :assignee))
    |> maybe_filter_milestone(Keyword.get(opts, :milestone))
    |> maybe_filter_search(Keyword.get(opts, :q))
    |> maybe_filter_blocked(Keyword.get(opts, :blocked))
  end

  def get_issue!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Issue, id: id, repository_id: repository_id)
  end

  def get_issue_by_number!(%Repository{id: repository_id}, number) when is_integer(number),
    do: Repo.get_by!(Issue, repository_id: repository_id, number: number)

  def get_issue_by_path!(owner, repository_name, number) when is_integer(number) do
    Repo.one!(
      from issue in Issue,
        join: repository in Repository,
        on: repository.id == issue.repository_id,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(repository_name) and
            repository.visibility == "public" and issue.number == ^number
    )
  end

  def create_issue(%Repository{} = repository, attrs),
    do: create_issue(repository, attrs, nil)

  def create_issue(%Repository{} = repository, attrs, author)
      when is_nil(author) or is_struct(author, User) do
    normalized =
      attrs
      |> to_string_map()
      |> Map.put("repository_id", repository.id)
      |> put_author(author)
      |> prepare_collections(repository)

    create_issue_with_number(repository, normalized, 20)
  end

  defp create_issue_with_number(repository, normalized, attempts_remaining) do
    Repo.transaction(fn ->
      number = next_issue_number(repository.id)
      normalized = Map.put(normalized, "number", number)

      with {:ok, issue} <- %Issue{} |> Issue.changeset(normalized) |> Repo.insert(),
           :ok <- sync_label_relationships(issue),
           :ok <- sync_assignee_relationships(issue) do
        issue
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:error, changeset} when attempts_remaining > 1 ->
        if number_conflict?(changeset, "issues_repository_id_number_index") do
          create_issue_with_number(repository, normalized, attempts_remaining - 1)
        else
          {:error, changeset}
        end

      {:ok, issue} ->
        Analytics.capture("issue_created", issue_distinct_id(normalized), %{
          "owner" => repository.owner,
          "repo" => repository.name,
          "has_labels" => has_labels?(normalized),
          "has_assignees" => has_assignees?(normalized)
        })

        Repositories.broadcast_issues(repository.id)

        {:ok, issue}

      result ->
        result
    end
  end

  def update_issue(issue, attrs, actor \\ nil)

  def update_issue(%Issue{} = issue, attrs, actor)
      when is_nil(actor) or is_struct(actor, User) do
    repository = %Repository{id: issue.repository_id}

    Repo.transaction(fn ->
      normalized =
        issue
        |> maybe_closed_attrs(attrs)
        |> to_string_map()
        |> Map.drop(["number", "repository_id", "author_user_id", "user"])
        |> prepare_collections(repository)

      with {:ok, updated} <- issue |> Issue.changeset(normalized) |> Repo.update(),
           :ok <- sync_label_relationships(updated),
           :ok <- sync_assignee_relationships(updated) do
        updated
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, updated} ->
        repository = Repo.get(Repository, issue.repository_id)

        Analytics.capture("issue_updated", actor_distinct_id(actor), %{
          "owner" => repository && repository.owner,
          "repo" => repository && repository.name,
          "state" => updated.state
        })

        Repositories.broadcast_issues(issue.repository_id)

        {:ok, updated}

      result ->
        result
    end
  end

  def change_issue(%Repository{id: repository_id}, %Issue{} = issue, attrs) do
    attrs = attrs |> to_string_map() |> Map.put("repository_id", repository_id)
    Issue.changeset(issue, attrs)
  end

  def change_issue(%Issue{repository_id: repository_id} = issue, attrs \\ %{})
      when not is_nil(repository_id) do
    Issue.changeset(issue, attrs)
  end

  def add_labels(%Issue{} = issue, names) when is_list(names) do
    repository = repository_stub(issue.repository_id)

    with {:ok, new_labels} <- resolve_or_create_labels(repository, names) do
      labels = ((issue.labels || []) ++ new_labels) |> Enum.uniq_by(& &1["name"])
      update_issue(issue, %{"labels" => labels})
    end
  end

  defp resolve_or_create_labels(repository, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, labels} ->
      case Labels.get_or_create_label_by_name(repository, name) do
        {:ok, label} -> {:cont, {:ok, [label_json(label) | labels]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, labels} -> {:ok, Enum.reverse(labels)}
      error -> error
    end
  end

  def remove_label(%Issue{} = issue, name) when is_binary(name) do
    decoded = URI.decode(name)
    labels = Enum.reject(issue.labels || [], &label_match?(&1, decoded))
    update_issue(issue, %{"labels" => labels})
  end

  def add_assignees(%Issue{} = issue, logins) when is_list(logins) do
    repository = repository_stub(issue.repository_id)

    new =
      Enum.map(logins, fn login ->
        repository
        |> Repositories.get_assignable_user_by_login!(login)
        |> assignee_json()
      end)

    assignees = ((issue.assignees || []) ++ new) |> Enum.uniq_by(& &1["login"])
    update_issue(issue, %{"assignees" => assignees})
  end

  def remove_assignees(%Issue{} = issue, logins) when is_list(logins) do
    logins = logins |> Enum.map(&String.downcase/1) |> MapSet.new()

    assignees =
      Enum.reject(issue.assignees || [], fn assignee ->
        String.downcase(assignee["login"]) in logins
      end)

    update_issue(issue, %{"assignees" => assignees})
  end

  @doc """
  The prerequisite edges touching `issues`, keyed by issue id.

  One query serves a whole page, so rendering a list never walks the graph once
  per row. Each entry carries what the issue waits on, what waits on it, and
  whether any prerequisite is still open.
  """
  def dependency_graph(issues) when is_list(issues) do
    ids = Enum.map(issues, & &1.id)
    base = Map.new(ids, &{&1, %{blocked_by: [], blocks: []}})

    from(dependency in IssueDependency,
      join: blocked in Issue,
      on: blocked.id == dependency.issue_id,
      join: blocker in Issue,
      on: blocker.id == dependency.blocked_by_issue_id,
      where: dependency.issue_id in ^ids or dependency.blocked_by_issue_id in ^ids,
      select: %{
        blocked_id: blocked.id,
        blocker_id: blocker.id,
        blocked_summary: %{number: blocked.number, title: blocked.title, state: blocked.state},
        blocker_summary: %{number: blocker.number, title: blocker.title, state: blocker.state}
      }
    )
    |> Repo.all()
    |> Enum.reduce(base, fn edge, graph ->
      graph
      |> collect_edge(edge.blocked_id, :blocked_by, edge.blocker_summary)
      |> collect_edge(edge.blocker_id, :blocks, edge.blocked_summary)
    end)
    |> Map.new(fn {id, entry} -> {id, derive_blocked(entry)} end)
  end

  @doc "The prerequisite edges of one issue, in the shape `dependency_graph/1` returns."
  def dependencies(%Issue{} = issue), do: [issue] |> dependency_graph() |> Map.fetch!(issue.id)

  defp collect_edge(graph, issue_id, key, summary) do
    case Map.fetch(graph, issue_id) do
      {:ok, entry} -> Map.put(graph, issue_id, Map.update!(entry, key, &[summary | &1]))
      :error -> graph
    end
  end

  # An issue is blocked while a prerequisite is still open, so the flag is read
  # from the prerequisites already loaded rather than stored on the issue.
  defp derive_blocked(%{blocked_by: blocked_by, blocks: blocks}) do
    blocked_by = Enum.sort_by(blocked_by, & &1.number)

    %{
      blocked_by: blocked_by,
      blocks: Enum.sort_by(blocks, & &1.number),
      blocked: Enum.any?(blocked_by, &(&1.state == "open"))
    }
  end

  @doc """
  Records the issues numbered `numbers` as prerequisites of `issue`.

  All of them or none: the numbers are validated and inserted in one
  transaction, so a request naming one unknown issue records nothing. Adding a
  prerequisite that is already recorded succeeds without a second row.

  Returns `:ok`, or `{:error, reason}` where reason is
  `{:invalid_number, value}`, `{:self_reference, number}`,
  `{:missing_issue, number}`, or `{:cycle, numbers}`. The cycle numbers name
  the path the edge would close, starting and ending at `issue`.
  """
  def add_dependencies(%Issue{} = issue, numbers, actor \\ nil)
      when is_list(numbers) and (is_nil(actor) or is_struct(actor, User)) do
    Repo.transaction(fn ->
      Enum.each(numbers, fn number ->
        case add_dependency(issue, number, actor) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
    |> case do
      {:ok, _result} ->
        Repositories.broadcast_issues(issue.repository_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_dependency(issue, number, actor) do
    with {:ok, number} <- normalize_issue_number(number),
         :ok <- reject_self_reference(issue, number),
         {:ok, blocker} <- fetch_blocker(issue, number),
         :ok <- reject_cycle(issue, blocker) do
      insert_dependency(issue, blocker, actor)
    end
  end

  defp normalize_issue_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp normalize_issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} -> normalize_issue_number(parsed)
      _other -> {:error, {:invalid_number, number}}
    end
  end

  defp normalize_issue_number(number), do: {:error, {:invalid_number, number}}

  defp reject_self_reference(%Issue{number: number}, number),
    do: {:error, {:self_reference, number}}

  defp reject_self_reference(_issue, _number), do: :ok

  defp fetch_blocker(issue, number) do
    case Repo.get_by(Issue, repository_id: issue.repository_id, number: number) do
      %Issue{} = blocker -> {:ok, blocker}
      nil -> {:error, {:missing_issue, number}}
    end
  end

  # The new edge closes a cycle exactly when the prerequisite already waits on
  # the issue it would block. A backlog whose graph can contain a cycle cannot
  # be scheduled, so the walk runs before the insert rather than at read time.
  defp reject_cycle(issue, blocker) do
    case dependency_path(blocker.id, issue.id) do
      nil -> :ok
      path -> {:error, {:cycle, [issue.number | issue_numbers(path)]}}
    end
  end

  defp dependency_path(from_id, target_id),
    do: walk_dependencies([[from_id]], MapSet.new([from_id]), target_id)

  defp walk_dependencies([], _visited, _target_id), do: nil

  defp walk_dependencies([path | queue], visited, target_id) do
    next_ids = blocker_ids(hd(path))

    if target_id in next_ids do
      Enum.reverse([target_id | path])
    else
      unvisited = Enum.reject(next_ids, &MapSet.member?(visited, &1))

      walk_dependencies(
        queue ++ Enum.map(unvisited, &[&1 | path]),
        Enum.into(unvisited, visited),
        target_id
      )
    end
  end

  defp blocker_ids(issue_id) do
    Repo.all(
      from dependency in IssueDependency,
        where: dependency.issue_id == ^issue_id,
        select: dependency.blocked_by_issue_id
    )
  end

  defp issue_numbers(ids) do
    numbers =
      from(issue in Issue, where: issue.id in ^ids, select: {issue.id, issue.number})
      |> Repo.all()
      |> Map.new()

    Enum.flat_map(ids, fn id ->
      case Map.fetch(numbers, id) do
        {:ok, number} -> [number]
        :error -> []
      end
    end)
  end

  defp insert_dependency(issue, blocker, actor) do
    %IssueDependency{}
    |> IssueDependency.changeset(%{
      "repository_id" => issue.repository_id,
      "issue_id" => issue.id,
      "blocked_by_issue_id" => blocker.id,
      "created_by_user_id" => actor && actor.id
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:issue_id, :blocked_by_issue_id])
    |> case do
      {:ok, _dependency} -> :ok
      {:error, changeset} -> {:error, {:invalid_dependency, changeset}}
    end
  end

  @doc """
  Removes the prerequisite numbered `number` from `issue`.

  Returns `{:error, {:missing_dependency, number}}` when the edge is not
  recorded, because a silent no-op hides the mismatch from the caller.
  """
  def remove_dependency(%Issue{} = issue, number) do
    with {:ok, number} <- normalize_issue_number(number),
         {:ok, blocker} <- fetch_blocker(issue, number) do
      from(dependency in IssueDependency,
        where: dependency.issue_id == ^issue.id and dependency.blocked_by_issue_id == ^blocker.id
      )
      |> Repo.delete_all()
      |> case do
        {0, _returned} ->
          {:error, {:missing_dependency, number}}

        {_count, _returned} ->
          Repositories.broadcast_issues(issue.repository_id)
          :ok
      end
    end
  end

  def set_milestone(%Issue{} = issue, nil) do
    update_issue(issue, %{"milestone" => nil})
  end

  def set_milestone(%Issue{} = issue, number) when is_integer(number) do
    milestone = Milestones.get_milestone_by_number!(repository_stub(issue.repository_id), number)
    update_issue(issue, %{"milestone" => milestone_json(milestone)})
  end

  def list_comments(%Issue{id: issue_id, repository_id: repository_id}) do
    Comment
    |> where(issue_id: ^issue_id, repository_id: ^repository_id)
    |> order_by(:created_at)
    |> Repo.all()
  end

  def get_comment!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Comment, id: id, repository_id: repository_id)
  end

  def get_comment_by_path!(owner, repository_name, id) do
    Repo.one!(
      from comment in Comment,
        join: repository in Repository,
        on: repository.id == comment.repository_id,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(repository_name) and
            repository.visibility == "public" and comment.id == ^id
    )
  end

  def create_comment(attrs) when is_map(attrs) do
    normalized = to_string_map(attrs)

    case Map.fetch(normalized, "issue_id") do
      {:ok, issue_id} ->
        case Repo.get(Issue, issue_id) do
          %Issue{} = issue -> create_comment(issue, normalized, nil)
          nil -> invalid_comment(normalized)
        end

      :error ->
        invalid_comment(normalized)
    end
  end

  defp invalid_comment(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Comment{}
    |> Comment.changeset(
      attrs
      |> Map.put_new("created_at", now)
      |> Map.put_new("updated_at", now)
    )
    |> Ecto.Changeset.apply_action(:insert)
  end

  def create_comment(%Issue{} = issue, attrs, author \\ nil)
      when is_nil(author) or is_struct(author, User) do
    normalized =
      attrs
      |> to_string_map()
      |> Map.put("issue_id", issue.id)
      |> Map.put("repository_id", issue.repository_id)
      |> put_author(author)
      |> Map.put_new("created_at", DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.put_new("updated_at", DateTime.utc_now() |> DateTime.truncate(:second))

    Repo.transaction(fn ->
      with {:ok, %Comment{} = comment} <-
             %Comment{} |> Comment.changeset(normalized) |> Repo.insert(),
           {1, nil} <-
             from(i in Issue,
               where: i.id == ^issue.id and i.repository_id == ^issue.repository_id,
               update: [inc: [comments: 1]]
             )
             |> Repo.update_all([]) do
        comment
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {_, _} -> Repo.rollback(%Comment{})
      end
    end)
    |> case do
      {:ok, comment} ->
        Analytics.capture("issue_commented", issue_distinct_id(normalized), %{
          "issue_number" => issue.number
        })

        Repositories.broadcast_issues(issue.repository_id)

        {:ok, comment}

      result ->
        result
    end
  end

  def update_comment(%Comment{} = comment, attrs) do
    normalized =
      attrs
      |> to_string_map()
      |> Map.drop(["issue_id", "repository_id", "author_user_id", "user"])
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.truncate(:second))

    comment
    |> Comment.changeset(normalized)
    |> Repo.update()
  end

  def delete_comment(%Comment{} = comment) do
    result =
      Repo.transaction(fn ->
        with {:ok, %Comment{}} <- Repo.delete(comment),
             {1, nil} <-
               from(i in Issue,
                 where: i.id == ^comment.issue_id and i.repository_id == ^comment.repository_id,
                 update: [inc: [comments: -1]]
               )
               |> Repo.update_all([]) do
          :ok
        else
          {:error, changeset} -> Repo.rollback(changeset)
          {_, _} -> Repo.rollback(:ok)
        end
      end)

    case result do
      {:ok, :ok} -> Repositories.broadcast_issues(comment.repository_id)
      _other -> :ok
    end

    result
  end

  defp prepare_collections(attrs, repository) do
    attrs
    |> maybe_convert_milestone(repository)
    |> maybe_convert_labels(repository)
    |> maybe_convert_assignees(repository)
  end

  defp maybe_convert_milestone(%{"milestone" => nil} = attrs, _repository) do
    attrs |> Map.put("milestone", nil) |> Map.put("milestone_id", nil)
  end

  defp maybe_convert_milestone(%{"milestone" => number} = attrs, repository)
       when is_integer(number) do
    milestone = Milestones.get_milestone_by_number!(repository, number)

    attrs
    |> Map.put("milestone", milestone_json(milestone))
    |> Map.put("milestone_id", milestone.id)
  end

  defp maybe_convert_milestone(%{"milestone" => milestone} = attrs, repository)
       when is_map(milestone) do
    number = milestone["number"] || milestone[:number]
    maybe_convert_milestone(Map.put(attrs, "milestone", number), repository)
  end

  defp maybe_convert_milestone(attrs, _repository), do: attrs

  defp maybe_convert_labels(%{"labels" => labels} = attrs, repository) when is_list(labels) do
    snapshots =
      Enum.map(labels, fn label ->
        name = if is_binary(label), do: label, else: label["name"] || label[:name]
        repository |> Labels.get_label_by_name!(name) |> label_json()
      end)

    Map.put(attrs, "labels", Enum.uniq_by(snapshots, & &1["name"]))
  end

  defp maybe_convert_labels(attrs, _repository), do: attrs

  defp maybe_convert_assignees(%{"assignees" => assignees} = attrs, repository)
       when is_list(assignees) do
    snapshots =
      Enum.map(assignees, fn assignee ->
        login = if is_binary(assignee), do: assignee, else: assignee["login"] || assignee[:login]
        repository |> Repositories.get_assignable_user_by_login!(login) |> assignee_json()
      end)

    Map.put(attrs, "assignees", Enum.uniq_by(snapshots, & &1["login"]))
  end

  defp maybe_convert_assignees(attrs, _repository), do: attrs

  defp sync_label_relationships(%Issue{} = issue) do
    Repo.delete_all(from row in "issue_labels", where: row.issue_id == ^issue.id)

    rows =
      Enum.map(issue.labels || [], fn snapshot ->
        label = Labels.get_label_by_name!(repository_stub(issue.repository_id), snapshot["name"])

        %{
          issue_id: issue.id,
          label_id: label.id,
          repository_id: issue.repository_id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end)

    if rows != [], do: Repo.insert_all("issue_labels", dump_repository_ids(rows))
    :ok
  end

  defp sync_assignee_relationships(%Issue{} = issue) do
    Repo.delete_all(from row in "issue_assignees", where: row.issue_id == ^issue.id)

    rows =
      Enum.map(issue.assignees || [], fn snapshot ->
        user =
          Repositories.get_assignable_user_by_login!(
            repository_stub(issue.repository_id),
            snapshot["login"]
          )

        %{
          issue_id: issue.id,
          user_id: user.id,
          repository_id: issue.repository_id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end)

    if rows != [], do: Repo.insert_all("issue_assignees", dump_repository_ids(rows))
    :ok
  end

  defp next_issue_number(repository_id) do
    case Repo.aggregate(from(i in Issue, where: i.repository_id == ^repository_id), :max, :number) do
      nil -> 1
      number -> number + 1
    end
  end

  defp number_conflict?(%Ecto.Changeset{} = changeset, constraint_name) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint_name] == constraint_name
    end)
  end

  defp put_author(attrs, nil), do: attrs

  defp put_author(attrs, %User{} = author) do
    attrs
    |> Map.put("author_user_id", author.id)
    |> Map.put("user", user_json(author))
  end

  defp issue_distinct_id(%{"author_user_id" => author_id}) when is_integer(author_id),
    do: Analytics.distinct_id(author_id)

  defp issue_distinct_id(_attrs), do: Analytics.system_distinct_id("api")

  defp actor_distinct_id(nil), do: Analytics.system_distinct_id("api")
  defp actor_distinct_id(%User{} = actor), do: Analytics.distinct_id(actor)

  defp has_labels?(%{"labels" => labels}) when is_list(labels), do: labels != []
  defp has_labels?(_attrs), do: false

  defp has_assignees?(%{"assignees" => assignees}) when is_list(assignees),
    do: assignees != []

  defp has_assignees?(_attrs), do: false

  defp dump_repository_ids(rows) do
    Enum.map(rows, fn row ->
      row = Map.update!(row, :repository_id, &Ecto.UUID.dump!/1)

      if Map.has_key?(row, :user_id) do
        Map.update!(row, :user_id, &Ecto.UUID.dump!/1)
      else
        row
      end
    end)
  end

  defp maybe_closed_attrs(issue, %{"state" => "closed"} = attrs) do
    if issue.state == "open" do
      attrs
      |> Map.put("closed_at", DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.put_new("state_reason", "completed")
    else
      attrs
    end
  end

  defp maybe_closed_attrs(_issue, %{"state" => "open"} = attrs) do
    attrs |> Map.put("closed_at", nil) |> Map.put("state_reason", nil)
  end

  defp maybe_closed_attrs(issue, %{state: "closed"} = attrs) do
    attrs =
      if issue.state == "open" and is_nil(attrs[:closed_at]) do
        Map.put(attrs, :closed_at, DateTime.utc_now() |> DateTime.truncate(:second))
      else
        attrs
      end

    Map.put_new(attrs, :state_reason, "completed")
  end

  defp maybe_closed_attrs(_issue, %{state: "open"} = attrs) do
    attrs |> Map.put(:closed_at, nil) |> Map.put(:state_reason, nil)
  end

  defp maybe_closed_attrs(_issue, attrs), do: attrs

  defp maybe_filter_state(query, "all"), do: query
  defp maybe_filter_state(query, state), do: where(query, state: ^state)

  # The label, assignee, and milestone filters read the JSONB snapshots that
  # already live on the issue row rather than joining the link tables. The
  # snapshots are maintained in the same transaction as the links, so a filter
  # over them cannot drift from what the API returns.
  defp maybe_filter_label(query, nil), do: query
  defp maybe_filter_label(query, ""), do: query

  defp maybe_filter_label(query, name) when is_binary(name) do
    decoded = URI.decode(name)

    where(
      query,
      [issue],
      fragment(
        "EXISTS (SELECT 1 FROM unnest(?) AS l WHERE l ->> 'name' = ?)",
        issue.labels,
        ^decoded
      )
    )
  end

  defp maybe_filter_assignee(query, nil), do: query
  defp maybe_filter_assignee(query, ""), do: query

  defp maybe_filter_assignee(query, login) when is_binary(login) do
    login_key = String.downcase(URI.decode(login))

    where(
      query,
      [issue],
      fragment(
        "EXISTS (SELECT 1 FROM unnest(?) AS a WHERE lower(a ->> 'login') = ?)",
        issue.assignees,
        ^login_key
      )
    )
  end

  # "Opened by me" has two honest answers. An issue filed here carries a
  # durable author link; an issue imported from GitHub carries only the login
  # in its user snapshot, because the account that opened it may not exist
  # here. Either one is the reader having opened it, so the filter takes both.
  defp maybe_filter_author(query, nil), do: query

  defp maybe_filter_author(query, %User{id: user_id, github_login: login}) do
    login_key = String.downcase(login)

    where(
      query,
      [issue],
      issue.author_user_id == ^user_id or
        fragment("lower(? ->> 'login')", issue.user) == ^login_key
    )
  end

  defp maybe_filter_milestone(query, nil), do: query
  defp maybe_filter_milestone(query, ""), do: query

  # The milestone snapshot on the row carries its own number, so the filter
  # reads the JSON instead of resolving a milestone row first. A number that
  # matches no milestone then simply matches no issues.
  defp maybe_filter_milestone(query, number) when is_integer(number),
    do: filter_milestone_number(query, number)

  defp maybe_filter_milestone(query, number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, _rest} -> filter_milestone_number(query, parsed)
      :error -> query
    end
  end

  defp filter_milestone_number(query, number) do
    where(
      query,
      [issue],
      fragment("coalesce((? ->> 'number')::int, -1)", issue.milestone) == ^number
    )
  end

  # Blocked is a property of the prerequisite's current state, so the filter
  # asks the graph rather than a column: an issue is blocked while any issue it
  # is blocked by is still open. Closing the last prerequisite moves the issue
  # into `blocked=false` with no second write.
  defp maybe_filter_blocked(query, nil), do: query

  defp maybe_filter_blocked(query, true),
    do: where(query, [], exists(open_blocker_query()))

  defp maybe_filter_blocked(query, false),
    do: where(query, [], not exists(open_blocker_query()))

  defp open_blocker_query do
    from dependency in IssueDependency,
      join: blocker in Issue,
      on: blocker.id == dependency.blocked_by_issue_id,
      where: dependency.issue_id == parent_as(:issue).id and blocker.state == "open",
      select: 1
  end

  defp maybe_filter_search(query, nil), do: query
  defp maybe_filter_search(query, ""), do: query

  defp maybe_filter_search(query, q) when is_binary(q) do
    # A percent sign typed into the box is a literal character, so the LIKE
    # wildcards are escaped before the needle is wrapped.
    escaped =
      q
      |> String.trim()
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    where(
      query,
      [issue],
      ilike(issue.title, ^"%#{escaped}%") or ilike(issue.body, ^"%#{escaped}%")
    )
  end

  defp to_string_map(attrs) do
    for {key, value} <- attrs, into: %{}, do: {to_string(key), value}
  end

  defp repository_stub(id), do: %Repository{id: id}

  defp label_json(%Label{} = label) do
    %{
      "id" => label.id,
      "name" => label.name,
      "color" => label.color,
      "description" => label.description
    }
  end

  defp milestone_json(%Milestone{} = milestone) do
    %{
      "number" => milestone.number,
      "title" => milestone.title,
      "state" => milestone.state,
      "description" => milestone.description,
      "due_on" => milestone.due_on
    }
  end

  defp user_json(%User{} = user) do
    %{
      "id" => user.github_id,
      "login" => user.github_login,
      "avatar_url" => user.github_avatar_url
    }
  end

  defp assignee_json(%User{} = user), do: %{"login" => user.github_login}
  defp label_match?(label, name), do: label["name"] == name
end
