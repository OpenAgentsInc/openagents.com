defmodule OpenAgents.Projects do
  @moduledoc "Repository-scoped projects and project items."

  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Analytics
  alias OpenAgents.Issues.Issue
  alias OpenAgents.ProjectFields.ProjectField
  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Projects.Project
  alias OpenAgents.Projects.ProjectNote
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  def list_projects(%Repository{id: repository_id}) do
    Project
    |> where(repository_id: ^repository_id)
    |> order_by(asc: :number)
    |> Repo.all()
  end

  @projects_per_page 25

  @doc "How many projects one workspace-wide page shows."
  def per_page, do: @projects_per_page

  @doc """
  One page of the projects `user` can read, across every repository, with the
  unpaginated total.

  Authorization is the same predicate the repository surfaces compose,
  `Repositories.readable_by/2`, joined in as a subquery rather than restated
  here, so a project in a repository the reader has no membership in cannot
  appear.

  Supported options: `:state`, `:owner`, and `:page`. Rows come back with their
  repository preloaded, because a project's board lives at a repository path.
  """
  def list_visible_projects_page(user, opts \\ [])
      when (is_nil(user) or is_struct(user, User)) and is_list(opts) do
    page = max(parse_page(opts[:page]), 1)
    query = visible_project_query(user, opts)

    total = Repo.aggregate(query, :count)

    projects =
      query
      |> order_by([project], desc: project.inserted_at, desc: project.id)
      |> limit(@projects_per_page)
      |> offset(^((page - 1) * @projects_per_page))
      |> Repo.all()
      |> Repo.preload(repository: :namespace)

    {projects, total}
  end

  @doc "How many projects `user` can read across every repository, filtered."
  def count_visible_projects(user, opts \\ [])
      when (is_nil(user) or is_struct(user, User)) and is_list(opts),
      do: user |> visible_project_query(opts) |> Repo.aggregate(:count)

  @doc "Clamps a reader-supplied page number into the bounded range."
  def parse_page(page), do: OpenAgents.Issues.parse_page(page)

  defp visible_project_query(user, opts) do
    readable = from(repository in Repositories.readable_by(Repository, user), select: repository)

    from(project in Project,
      join: repository in subquery(readable),
      on: repository.id == project.repository_id
    )
    |> maybe_filter_project_state(Keyword.get(opts, :state, "open"))
    |> maybe_filter_project_owner(Keyword.get(opts, :owner))
  end

  defp maybe_filter_project_state(query, "all"), do: query
  defp maybe_filter_project_state(query, state), do: where(query, state: ^state)

  # As with issues, a project created here carries a durable owner link while
  # one that arrived with only a login carries the login.
  defp maybe_filter_project_owner(query, nil), do: query

  defp maybe_filter_project_owner(query, %User{id: user_id, github_login: login}) do
    login_key = String.downcase(login)

    where(
      query,
      [project],
      project.owner_user_id == ^user_id or fragment("lower(?)", project.owner) == ^login_key
    )
  end

  def get_project!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Project, id: id, repository_id: repository_id)
  end

  def get_project_by_number!(%Repository{id: repository_id}, number) when is_integer(number),
    do: Repo.get_by!(Project, repository_id: repository_id, number: number)

  def get_project_by_path!(owner, repository_name, number) when is_integer(number) do
    Repo.one!(
      from project in Project,
        join: repository in Repository,
        on: repository.id == project.repository_id,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(repository_name) and
            repository.visibility == "public" and project.number == ^number
    )
  end

  def create_project(%Repository{} = repository, attrs),
    do: create_project(repository, attrs, nil)

  def create_project(%Repository{} = repository, attrs, owner_user)
      when is_nil(owner_user) or is_struct(owner_user, User) do
    normalized = to_string_map(attrs)
    explicit_number? = Map.has_key?(normalized, "number")

    normalized =
      normalized
      |> Map.put("repository_id", repository.id)
      |> put_owner(owner_user)

    create_project_with_number(repository, normalized, explicit_number?, owner_user, 20)
  end

  defp create_project_with_number(
         repository,
         normalized,
         explicit_number?,
         owner_user,
         attempts_remaining
       ) do
    normalized = Map.put_new(normalized, "number", next_project_number(repository.id))

    %Project{}
    |> Project.changeset(normalized)
    |> Repo.insert()
    |> case do
      {:error, changeset} when not explicit_number? and attempts_remaining > 1 ->
        if number_conflict?(changeset) do
          normalized = Map.delete(normalized, "number")

          create_project_with_number(
            repository,
            normalized,
            false,
            owner_user,
            attempts_remaining - 1
          )
        else
          {:error, changeset}
        end

      {:ok, project} ->
        Analytics.capture("project_created", actor_distinct_id(owner_user), %{
          "owner" => repository.owner,
          "repo" => repository.name
        })

        Repositories.broadcast_projects(repository.id)

        {:ok, project}

      result ->
        result
    end
  end

  defp actor_distinct_id(nil), do: Analytics.system_distinct_id("api")
  defp actor_distinct_id(%User{} = actor), do: Analytics.distinct_id(actor)

  def update_project(%Project{} = project, attrs), do: update_project(project, attrs, nil)

  @doc """
  Updates `project` and records what changed in its activity log.

  Every accepted change to the title, description, or state appends one
  immutable `"activity"` note, so a board carries the decision record even
  when nobody wrote discussion around it. The note is written in the same
  transaction as the update: an activity entry for a change that did not
  commit would be a false record.
  """
  def update_project(%Project{} = project, attrs, actor)
      when is_nil(actor) or is_struct(actor, User) do
    attrs = attrs |> to_string_map() |> Map.drop(["repository_id", "owner_user_id"])

    attrs =
      if project.owner_user_id do
        Map.drop(attrs, ["owner"])
      else
        attrs
      end

    changeset = Project.changeset(project, attrs)

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, updated} ->
          Enum.each(activity_bodies(changeset), fn body ->
            case insert_note(updated, %{"body" => body, "kind" => "activity"}, actor) do
              {:ok, _note} -> :ok
              {:error, note_changeset} -> Repo.rollback(note_changeset)
            end
          end)

          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, project} ->
        Repositories.broadcast_projects(project.repository_id)
        {:ok, project}

      result ->
        result
    end
  end

  # One line per changed property, in a fixed order so a reader of the log sees
  # the same shape every time. Only these three are worth a record: the rest of
  # a project's columns are its identity, not its operating state.
  defp activity_bodies(changeset) do
    Enum.flat_map(
      [
        {:state, &"Changed the state to `#{&1}`."},
        {:title, &"Changed the title to #{inspect(&1)}."},
        {:description, &describe_description_change/1}
      ],
      fn {field, describe} ->
        case Ecto.Changeset.fetch_change(changeset, field) do
          {:ok, value} -> [describe.(value)]
          :error -> []
        end
      end
    )
  end

  defp describe_description_change(nil), do: "Removed the description."
  defp describe_description_change(""), do: "Removed the description."
  defp describe_description_change(_value), do: "Updated the description."

  def delete_project(%Project{} = project) do
    Repo.delete(project)
    |> case do
      {:ok, project} ->
        Repositories.broadcast_projects(project.repository_id)
        {:ok, project}

      result ->
        result
    end
  end

  def change_project(%Repository{id: repository_id}, %Project{} = project, attrs) do
    attrs = attrs |> to_string_map() |> Map.put("repository_id", repository_id)
    Project.changeset(project, attrs)
  end

  def change_project(%Project{repository_id: repository_id} = project, attrs \\ %{})
      when not is_nil(repository_id) do
    Project.changeset(project, attrs)
  end

  @notes_per_page 20

  @doc "How many project notes one page carries."
  def notes_per_page, do: @notes_per_page

  @doc """
  One page of `project`'s notes, newest first, with the unpaginated total.

  A project object never embeds its timeline: a long-lived board accumulates
  decisions without bound, so the notes are a separate paginated read. Page 1
  is the most recent `notes_per_page/0` entries, which is what an operator
  opening a board wants first.

  Supported options: `:page` and `:kind`. `:kind` takes `"note"` for
  discussion, `"activity"` for the immutable change record, or `"all"`, the
  default.

  Authority is the project's repository, which the caller has already resolved
  through `OpenAgents.Repositories.get_visible_by_path!/3` or its writable
  counterpart. Notes carry no separate visibility of their own.
  """
  def list_project_notes_page(%Project{} = project, opts \\ []) when is_list(opts) do
    query = project_notes_query(project, opts)
    page = max(parse_page(opts[:page]), 1)

    notes =
      query
      |> order_by([note], desc: note.inserted_at, desc: note.id)
      |> limit(@notes_per_page)
      |> offset(^((page - 1) * @notes_per_page))
      |> Repo.all()
      |> Repo.preload(:author_user)

    {notes, Repo.aggregate(query, :count)}
  end

  @doc "How many notes `project` carries, with the same filters."
  def count_project_notes(%Project{} = project, opts \\ []) when is_list(opts),
    do: project |> project_notes_query(opts) |> Repo.aggregate(:count)

  @doc "One note of `project`, by id."
  def get_project_note!(%Project{id: project_id, repository_id: repository_id}, id) do
    ProjectNote
    |> Repo.get_by!(id: id, project_id: project_id, repository_id: repository_id)
    |> Repo.preload(:author_user)
  end

  @doc """
  Writes one discussion note on `project`, authored by `author`.

  The caller establishes write authority on the project's repository first.
  `kind` is not accepted from outside: activity entries are written only by the
  context that made the change they record.
  """
  def create_project_note(%Project{} = project, attrs, author \\ nil)
      when is_nil(author) or is_struct(author, User) do
    attrs =
      attrs
      |> to_string_map()
      |> Map.take(["body"])
      |> Map.put("kind", "note")

    case insert_note(project, attrs, author) do
      {:ok, note} ->
        Analytics.capture("project_note_created", actor_distinct_id(author), %{
          "project_number" => project.number
        })

        Repositories.broadcast_projects(project.repository_id)

        {:ok, Repo.preload(note, :author_user)}

      result ->
        result
    end
  end

  @doc """
  Edits the body of one discussion note.

  An activity entry is the record of a change that happened, so it is
  immutable: this returns `{:error, :immutable}` for one. Authority to call
  this is the note's author, which the caller checks with
  `authored_by?/2`.
  """
  def update_project_note(%ProjectNote{kind: "activity"}, _attrs), do: {:error, :immutable}

  def update_project_note(%ProjectNote{} = note, attrs) do
    attrs = attrs |> to_string_map() |> Map.take(["body"])

    note
    |> ProjectNote.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, note} ->
        Repositories.broadcast_projects(note.repository_id)
        {:ok, Repo.preload(note, :author_user)}

      result ->
        result
    end
  end

  @doc "Deletes one discussion note. Activity entries never delete."
  def delete_project_note(%ProjectNote{kind: "activity"}), do: {:error, :immutable}

  def delete_project_note(%ProjectNote{} = note) do
    case Repo.delete(note) do
      {:ok, note} ->
        Repositories.broadcast_projects(note.repository_id)
        {:ok, note}

      result ->
        result
    end
  end

  @doc """
  Whether `user` wrote `note`.

  Edit and delete authority for a discussion note is its author, and nobody
  else: repository write access adds a note of your own rather than rewriting
  somebody else's words. A note written without an authenticated author, by an
  import or a token with no user behind it, has no author to match, so it is
  not editable through this predicate.
  """
  def authored_by?(%ProjectNote{author_user_id: nil}, _user), do: false
  def authored_by?(%ProjectNote{}, nil), do: false

  def authored_by?(%ProjectNote{author_user_id: author_user_id}, %User{id: user_id}),
    do: author_user_id == user_id

  @doc "A blank or seeded changeset for the note form."
  def change_project_note(%ProjectNote{} = note \\ %ProjectNote{}, attrs \\ %{}),
    do: ProjectNote.changeset(note, to_string_map(attrs))

  defp project_notes_query(%Project{id: project_id, repository_id: repository_id}, opts) do
    from(note in ProjectNote,
      where: note.project_id == ^project_id and note.repository_id == ^repository_id
    )
    |> maybe_filter_note_kind(Keyword.get(opts, :kind, "all"))
  end

  defp maybe_filter_note_kind(query, kind) when kind in ["note", "activity"],
    do: where(query, kind: ^kind)

  defp maybe_filter_note_kind(query, _all), do: query

  defp insert_note(%Project{} = project, attrs, author) do
    attrs
    |> Map.put("project_id", project.id)
    |> Map.put("repository_id", project.repository_id)
    |> put_note_author(author)
    |> then(&ProjectNote.changeset(%ProjectNote{}, &1))
    |> Repo.insert()
  end

  defp put_note_author(attrs, nil), do: attrs

  defp put_note_author(attrs, %User{} = author) do
    attrs
    |> Map.put("author_user_id", author.id)
    |> Map.put("author", %{"login" => author.github_login})
  end

  def list_project_items(%Project{id: project_id, repository_id: repository_id}) do
    project_items_query(project_id, repository_id)
    |> order_by(asc: :id)
    |> preload(issue: :repository)
    |> Repo.all()
  end

  def list_visible_project_items(
        %Project{id: project_id, repository_id: repository_id},
        user
      ) do
    readable =
      from(repository in Repositories.readable_by(Repository, user), select: repository.id)

    project_items_query(project_id, repository_id)
    |> where([item], item.issue_repository_id in subquery(readable))
    |> order_by(asc: :id)
    |> preload(issue: :repository)
    |> Repo.all()
  end

  def get_project_item!(%Project{id: project_id, repository_id: repository_id}, id) do
    ProjectItem
    |> Repo.get_by!(
      id: id,
      project_id: project_id,
      repository_id: repository_id
    )
    |> Repo.preload(issue: :repository)
  end

  def get_visible_project_item!(
        %Project{id: project_id, repository_id: repository_id},
        id,
        user
      ) do
    readable =
      from(repository in Repositories.readable_by(Repository, user), select: repository.id)

    project_items_query(project_id, repository_id)
    |> where([item], item.id == ^id and item.issue_repository_id in subquery(readable))
    |> preload(issue: :repository)
    |> Repo.one!()
  end

  def create_project_item(attrs, project, actor \\ nil)

  def create_project_item(attrs, %Project{} = project, actor)
      when is_nil(actor) or is_struct(actor, User) do
    attrs = to_string_map(attrs)
    values = Map.get(attrs, "values", %{})
    issue_repository_id = Map.get(attrs, "issue_repository_id", project.repository_id)

    result =
      case Map.get(attrs, "issue_number") do
        nil ->
          %ProjectItem{}
          |> ProjectItem.changeset(%{
            "project_id" => project.id,
            "repository_id" => project.repository_id,
            "issue_repository_id" => issue_repository_id,
            "values" => values
          })
          |> Ecto.Changeset.apply_action(:insert)

        issue_number ->
          issue =
            Repo.get_by!(Issue,
              repository_id: issue_repository_id,
              number: issue_number
            )

          %ProjectItem{}
          |> ProjectItem.changeset(%{
            "project_id" => project.id,
            "issue_id" => issue.id,
            "repository_id" => project.repository_id,
            "issue_repository_id" => issue_repository_id,
            "values" => values
          })
          |> Repo.insert()
      end

    case result do
      {:ok, item} ->
        Analytics.capture("project_item_added", actor_distinct_id(actor), %{
          "project_number" => project.number,
          "has_issue" => match?(%ProjectItem{issue_id: id} when id != nil, item)
        })

        {:ok, Repo.preload(item, issue: :repository)}

      result ->
        result
    end
  end

  def update_project_item(%ProjectItem{} = item, attrs) do
    attrs = to_string_map(attrs)
    values = Map.merge(item.values || %{}, Map.get(attrs, "values", %{}))

    item
    |> ProjectItem.changeset(%{"values" => values})
    |> Repo.update()
  end

  def list_project_fields(%Project{id: project_id}) do
    ProjectField
    |> where(project_id: ^project_id)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  def create_project_field(attrs) do
    %ProjectField{}
    |> ProjectField.changeset(attrs)
    |> Repo.insert()
  end

  defp next_project_number(repository_id) do
    case Repo.aggregate(
           from(project in Project, where: project.repository_id == ^repository_id),
           :max,
           :number
         ) do
      nil -> 1
      number -> number + 1
    end
  end

  defp project_items_query(project_id, repository_id) do
    from(item in ProjectItem,
      where: item.project_id == ^project_id and item.repository_id == ^repository_id
    )
  end

  defp number_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint_name] == "projects_repository_id_number_index"
    end)
  end

  defp put_owner(attrs, nil), do: attrs

  defp put_owner(attrs, %User{} = owner) do
    attrs
    |> Map.put("owner", owner.github_login)
    |> Map.put("owner_user_id", owner.id)
  end

  defp to_string_map(attrs) do
    for {key, value} <- attrs, into: %{}, do: {to_string(key), value}
  end
end
