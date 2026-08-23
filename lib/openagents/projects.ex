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
  alias OpenAgents.Projects.ProjectItemEvent
  alias OpenAgents.Projects.PromiseRegistry
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @doc """
  The projects of one repository, in board order.

  Archived projects are out of the working set, so they are left out unless
  `archived: true` asks for them. Nothing else about them changes: an archived
  board reads, and comes back, exactly as it was.
  """
  def list_projects(repository, opts \\ [])

  def list_projects(%Repository{id: repository_id}, opts) when is_list(opts) do
    Project
    |> where(repository_id: ^repository_id)
    |> filter_archived(Keyword.get(opts, :archived, false))
    |> order_by(asc: :number)
    |> Repo.all()
  end

  defp filter_archived(query, true), do: query
  defp filter_archived(query, _excluded), do: where(query, [project], is_nil(project.archived_at))

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
    |> filter_archived(Keyword.get(opts, :archived, false))
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
  Moves `project` into the archive, attributed to `actor`.

  Archiving is orthogonal to closing. A closed project says the work it tracked
  reached an end; an archived project says the board is out of the working set,
  whatever became of the work. Archiving is reversible through
  `restore_project/2`, and it is the precondition the API puts in front of a
  project delete.
  """
  def archive_project(%Project{} = project, actor \\ nil),
    do: update_project(project, %{"archived" => true}, actor)

  @doc "Brings `project` back out of the archive, attributed to `actor`."
  def restore_project(%Project{} = project, actor \\ nil),
    do: update_project(project, %{"archived" => false}, actor)

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

    {attrs, archived_error} = put_archived_at(project, attrs)

    changeset =
      case archived_error do
        nil -> Project.changeset(project, attrs)
        message -> Ecto.Changeset.add_error(Project.changeset(project, attrs), :archived, message)
      end

    if changeset.valid? do
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
    else
      {:error, changeset}
    end
  end

  # `archived` is a boolean on the wire because that is the question a caller
  # is asking. The column is a timestamp because the answer is worth dating.
  # Re-archiving an archived project keeps the original timestamp: the board
  # left the working set once.
  defp put_archived_at(project, attrs) do
    case Map.pop(attrs, "archived") do
      {nil, attrs} ->
        {attrs, nil}

      {true, attrs} ->
        at = project.archived_at || DateTime.truncate(DateTime.utc_now(), :second)
        {Map.put(attrs, "archived_at", at), nil}

      {false, attrs} ->
        {Map.put(attrs, "archived_at", nil), nil}

      {_other, attrs} ->
        {attrs, "is invalid"}
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
        {:description, &describe_description_change/1},
        {:archived_at, &describe_archive_change/1}
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

  defp describe_archive_change(nil), do: "Restored the project from the archive."
  defp describe_archive_change(_at), do: "Archived the project."

  @doc """
  Deletes `project` along with its fields and items.

  The items go, the issues stay. A project item is a reference to a canonical
  issue, so deleting the board that referenced it must never delete the work.
  Notes and activity cascade from the database. Project item events do not:
  they are append-only, and the record of what a promise did outlives the board
  that carried it.
  """
  def delete_project(%Project{} = project) do
    Repo.transaction(fn ->
      Repo.delete_all(from field in ProjectField, where: field.project_id == ^project.id)
      Repo.delete_all(from item in ProjectItem, where: item.project_id == ^project.id)
      Repo.delete!(project)
    end)
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
        %Project{id: project_id, repository_id: repository_id} = project,
        user,
        opts \\ []
      ) do
    promise_context =
      Keyword.get(opts, :promise_context, PromiseRegistry.context(project))

    readable =
      from(repository in Repositories.readable_by(Repository, user), select: repository.id)

    items =
      project_items_query(project_id, repository_id)
      |> where([item], item.issue_repository_id in subquery(readable))
      |> order_by(asc: :id)
      |> preload(issue: :repository)
      |> Repo.all()

    Enum.filter(items, fn item ->
      state_matches? =
        case opts[:promise_state] do
          nil -> true
          state -> PromiseRegistry.state(promise_context, item.values) == state
        end

      bounty_matches? =
        case opts[:bounty_candidate] do
          nil -> true
          value -> PromiseRegistry.bounty_candidate?(promise_context, item.values) == value
        end

      state_matches? and bounty_matches?
    end)
  end

  def list_visible_project_items_with_promises(%Project{} = project, user, opts \\ []) do
    promise_context = PromiseRegistry.context(project)

    items =
      list_visible_project_items(
        project,
        user,
        Keyword.put(opts, :promise_context, promise_context)
      )

    {items, project_item_projections(items, promise_context, user)}
  end

  def project_item_projections(items, promise_context, reader) do
    Map.new(items, fn item ->
      values = PromiseRegistry.redact_values(item.values, reader)

      {item.id,
       %{
         values: values,
         promise: PromiseRegistry.projection_from_redacted(promise_context, values)
       }}
    end)
  end

  def project_item_events(events, reader) do
    Enum.map(events, fn event ->
      changes =
        case event.changes do
          %{"values" => values} ->
            %{"values" => PromiseRegistry.redact_values(values, reader)}

          changes ->
            changes
        end

      %{event | changes: changes}
    end)
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
          changeset =
            ProjectItem.changeset(%ProjectItem{}, %{
              "project_id" => project.id,
              "repository_id" => project.repository_id,
              "issue_repository_id" => issue_repository_id,
              "values" => values
            })

          if PromiseRegistry.registry?(project) do
            Ecto.Changeset.add_error(
              changeset,
              :issue_id,
              "is required for promise registry items"
            )
          else
            Ecto.Changeset.apply_action(changeset, :insert)
          end

        issue_number ->
          issue =
            Repo.get_by!(Issue,
              repository_id: issue_repository_id,
              number: issue_number
            )

          item_attrs = %{
            "project_id" => project.id,
            "issue_id" => issue.id,
            "repository_id" => project.repository_id,
            "issue_repository_id" => issue_repository_id,
            "values" => values
          }

          case prepare_promise_values(project, values, actor) do
            {:ok, values} ->
              insert_project_item(Map.put(item_attrs, "values", values), project, actor)

            {:error, errors} ->
              item_attrs
              |> then(&ProjectItem.changeset(%ProjectItem{}, &1))
              |> add_errors(errors)
              |> then(&{:error, &1})
          end
      end

    case result do
      {:ok, item} ->
        Analytics.capture("project_item_added", actor_distinct_id(actor), %{
          "project_number" => project.number,
          "has_issue" => match?(%ProjectItem{issue_id: id} when id != nil, item)
        })

        Repositories.broadcast_projects(project.repository_id)

        {:ok, Repo.preload(item, issue: :repository)}

      result ->
        result
    end
  end

  @doc """
  Records new field values on one project item.

  A committed change announces itself on the repository's project topic, the
  same way every other project write does. A card's `Status` is a stored field
  value, so a board that did not hear about this write would keep rendering the
  card in the column it left — the write path, not the caller, owns the
  announcement, so a change made over `/api/v3` and a change made from the
  board produce the same event.
  """
  def update_project_item(%ProjectItem{} = item, attrs, actor \\ nil) do
    attrs = to_string_map(attrs)

    values =
      case Map.get(attrs, "values", %{}) do
        incoming when is_map(incoming) -> Map.merge(item.values || %{}, incoming)
        incoming -> incoming
      end

    project = Repo.get!(Project, item.project_id)

    case prepare_promise_values(project, values, actor, item.id) do
      {:ok, values} ->
        changeset = ProjectItem.changeset(item, %{"values" => values})

        Repo.transaction(fn ->
          updated = Repo.update!(changeset)
          record_promise_event(updated, project, actor, item.values || %{}, values, "update")
          updated
        end)
        |> case do
          {:ok, updated} ->
            Repositories.broadcast_projects(project.repository_id)
            {:ok, Repo.preload(updated, issue: :repository)}

          result ->
            result
        end

      {:error, errors} ->
        {:error, add_errors(ProjectItem.changeset(item, %{"values" => values}), errors)}
    end
  end

  def list_project_fields(%Project{id: project_id}) do
    ProjectField
    |> where(project_id: ^project_id)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  @doc "One field of `project`, by id."
  def get_project_field!(%Project{id: project_id}, id),
    do: Repo.get_by!(ProjectField, id: id, project_id: project_id)

  def create_project_field(attrs), do: create_project_field(attrs, nil)

  @doc """
  Declares one field on a project, attributed to `actor`.

  A project carries at most one `promise_state` field, because the promise
  registry reads a single stored state per item.
  """
  def create_project_field(attrs, actor) when is_nil(actor) or is_struct(actor, User) do
    changeset =
      %ProjectField{}
      |> ProjectField.changeset(attrs)
      |> PromiseRegistry.validate_field()
      |> validate_promise_field_available()

    if changeset.valid? do
      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, field} ->
            record_field_activity(field.project_id, "Added the field `#{field.name}`.", actor)
            field

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, changeset}
    end
  end

  @doc """
  Updates one field of `project`, attributed to `actor`.

  A field's name is the key its values are stored under on every item, so a
  rename rewrites that key across the project's items in the same transaction:
  a rename that left the values behind would silently empty the column.

  The data type never changes. Values already stored were written against the
  old type, and reinterpreting them is a destructive change wearing an edit's
  clothes — declare a new field instead.

  Options grow freely, and an option written as an object keeps its identifier
  while its label changes. Removing an option that items still carry is
  refused, so a removal cannot strand the values that chose it.
  """
  def update_project_field(project, field, attrs, actor \\ nil)

  def update_project_field(
        %Project{id: project_id} = project,
        %ProjectField{project_id: project_id} = field,
        attrs,
        actor
      )
      when is_nil(actor) or is_struct(actor, User) do
    attrs = attrs |> to_string_map() |> Map.take(["name", "data_type", "options"])

    changeset =
      field
      |> ProjectField.changeset(Map.put(attrs, "project_id", field.project_id))
      |> refuse_data_type_change()
      |> PromiseRegistry.validate_field()
      |> refuse_stranded_options(project, field)

    if changeset.valid? do
      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, updated} ->
            rename_item_values(project, field.name, updated.name)

            Enum.each(field_activity_bodies(field, updated), fn body ->
              record_field_activity(project.id, body, actor)
            end)

            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, updated} ->
          Repositories.broadcast_projects(project.repository_id)
          {:ok, updated}

        result ->
          result
      end
    else
      {:error, changeset}
    end
  end

  @doc """
  Removes one field of `project`, attributed to `actor`.

  A field whose values items still carry is preserved instead: deleting it
  would leave those values keyed to a column nothing declares, which is data
  loss reported as success.
  """
  def delete_project_field(project, field, actor \\ nil)

  def delete_project_field(
        %Project{id: project_id} = project,
        %ProjectField{project_id: project_id} = field,
        actor
      )
      when is_nil(actor) or is_struct(actor, User) do
    case count_items_carrying(project, field.name) do
      0 ->
        Repo.transaction(fn ->
          Repo.delete!(field)
          record_field_activity(project.id, "Removed the field `#{field.name}`.", actor)
          field
        end)
        |> case do
          {:ok, deleted} ->
            Repositories.broadcast_projects(project.repository_id)
            {:ok, deleted}

          result ->
            result
        end

      count ->
        {:error,
         field
         |> ProjectField.changeset(%{})
         |> Ecto.Changeset.add_error(
           :name,
           "is still carried by #{count} #{pluralize(count, "item")}"
         )}
    end
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  # A rename is a key rewrite on every item of the project. Postgres does it in
  # one statement: drop the old key, then write the value back under the new
  # one.
  defp rename_item_values(_project, name, name), do: :ok

  defp rename_item_values(%Project{id: project_id}, old_name, new_name) do
    from(item in ProjectItem,
      where:
        item.project_id == ^project_id and
          fragment("jsonb_exists(?, ?::text)", item.values, ^old_name),
      update: [
        set: [
          values:
            fragment(
              "(? - ?::text) || jsonb_build_object(?::text, ? -> ?::text)",
              item.values,
              ^old_name,
              ^new_name,
              item.values,
              ^old_name
            )
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  defp count_items_carrying(%Project{id: project_id}, name) do
    Repo.aggregate(
      from(item in ProjectItem,
        where:
          item.project_id == ^project_id and
            fragment("jsonb_exists(?, ?::text)", item.values, ^name)
      ),
      :count
    )
  end

  defp refuse_data_type_change(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :data_type) do
      {:ok, _data_type} ->
        Ecto.Changeset.add_error(
          changeset,
          :data_type,
          "cannot change once the field exists; declare a new field instead"
        )

      :error ->
        changeset
    end
  end

  defp refuse_stranded_options(changeset, %Project{} = project, %ProjectField{} = field) do
    case Ecto.Changeset.fetch_change(changeset, :options) do
      :error ->
        changeset

      {:ok, _options} ->
        kept = ProjectField.option_ids(Ecto.Changeset.apply_changes(changeset))
        removed = ProjectField.option_ids(field) -- kept

        case options_in_use(project, field.name, removed) do
          [] ->
            changeset

          in_use ->
            Ecto.Changeset.add_error(
              changeset,
              :options,
              "cannot drop #{Enum.map_join(in_use, ", ", &"`#{&1}`")} while items still carry them"
            )
        end
    end
  end

  defp options_in_use(_project, _name, []), do: []

  defp options_in_use(%Project{id: project_id}, name, removed) do
    Repo.all(
      from item in ProjectItem,
        where:
          item.project_id == ^project_id and
            fragment("?->>?::text", item.values, ^name) in ^removed,
        select: fragment("?->>?::text", item.values, ^name),
        distinct: true
    )
  end

  defp field_activity_bodies(%ProjectField{} = before, %ProjectField{} = now) do
    rename =
      if before.name != now.name,
        do: ["Renamed the field `#{before.name}` to `#{now.name}`."],
        else: []

    options =
      if before.options != now.options,
        do: ["Updated the options of the field `#{now.name}`."],
        else: []

    rename ++ options
  end

  defp record_field_activity(project_id, body, actor) do
    case Repo.get(Project, project_id) do
      nil ->
        :ok

      %Project{} = project ->
        case insert_note(project, %{"body" => body, "kind" => "activity"}, actor) do
          {:ok, _note} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  defp validate_promise_field_available(changeset) do
    if promise_field_available?(changeset) do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :data_type,
        "already exists on this project"
      )
    end
  end

  # Only values a declared field claims are checked. A value under a key no
  # field declares passes through untouched: a board can carry notes the
  # schema has not caught up with, and rejecting them would break every client
  # that stored a value before its field existed.
  defp validate_field_values(%Project{} = project, values) when is_map(values) do
    errors =
      project
      |> list_project_fields()
      |> Enum.flat_map(fn field ->
        case Map.fetch(values, field.name) do
          :error -> []
          {:ok, nil} -> []
          {:ok, value} -> field_value_errors(field, value)
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, %{values: errors}}
    end
  end

  defp validate_field_values(_project, _values), do: :ok

  defp field_value_errors(%ProjectField{data_type: "text", name: name}, value)
       when not is_binary(value),
       do: ["#{name} must be text"]

  defp field_value_errors(%ProjectField{data_type: "number", name: name}, value)
       when not is_number(value),
       do: ["#{name} must be a number"]

  defp field_value_errors(%ProjectField{data_type: "date", name: name}, value) do
    case is_binary(value) and Date.from_iso8601(value) do
      {:ok, _date} -> []
      _invalid -> ["#{name} must be an ISO 8601 date"]
    end
  end

  defp field_value_errors(%ProjectField{data_type: "single_select"} = field, value) do
    if value in ProjectField.option_ids(field) do
      []
    else
      ["#{field.name} must be one of the field's options"]
    end
  end

  # A promise state carries its own gate checks in `PromiseRegistry`, which
  # reports richer reasons than "not one of the options" would.
  defp field_value_errors(%ProjectField{}, _value), do: []

  def list_project_item_events(%ProjectItem{id: item_id}, opts \\ []) do
    page = max(parse_page(opts[:page]), 1)
    per_page = 25
    query = from event in ProjectItemEvent, where: event.project_item_id == ^item_id
    total = Repo.aggregate(query, :count)

    events =
      query
      |> order_by([event], desc: event.occurred_at, desc: event.id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {events, total, page, per_page}
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

  defp prepare_promise_values(project, values, actor, exclude_id \\ nil)

  defp prepare_promise_values(_project, values, _actor, _exclude_id) when not is_map(values) do
    {:error, %{values: ["must be a map"]}}
  end

  defp prepare_promise_values(project, values, actor, exclude_id) do
    with :ok <- validate_field_values(project, values) do
      prepare_promise_values!(project, values, actor, exclude_id)
    end
  end

  defp prepare_promise_values!(project, values, actor, exclude_id) do
    case PromiseRegistry.validate_values(project, values, actor) do
      {:ok, values} ->
        if PromiseRegistry.registry?(project) do
          promise_id = get_in(values, ["promise", "id"])

          if promise_id && promise_id_taken?(project.id, promise_id, exclude_id) do
            {:error, %{values: ["promise.id must be unique within this project"]}}
          else
            {:ok, values}
          end
        else
          {:ok, values}
        end

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp insert_project_item(attrs, project, actor) do
    Repo.transaction(fn ->
      case Repo.insert(ProjectItem.changeset(%ProjectItem{}, attrs)) do
        {:ok, item} ->
          if PromiseRegistry.registry?(project) do
            record_promise_event(item, project, actor, %{}, item.values || %{}, "create")
          end

          item

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, item} -> {:ok, Repo.preload(item, issue: :repository)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_promise_event(item, project, actor, previous, values, kind) do
    from_state = PromiseRegistry.state(project, previous)
    to_state = PromiseRegistry.state(project, values)
    kind = if from_state && from_state != to_state, do: "state_change", else: kind

    %ProjectItemEvent{}
    |> ProjectItemEvent.changeset(%{
      project_item_id: item.id,
      project_id: project.id,
      repository_id: project.repository_id,
      actor_user_id: actor && actor.id,
      actor_login: actor_login(actor),
      kind: kind,
      from_state: from_state,
      to_state: to_state,
      changes: %{"values" => values},
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp actor_login(nil), do: "system"
  defp actor_login(%User{github_login: login}) when is_binary(login), do: login
  defp actor_login(_actor), do: "system"

  defp promise_field_available?(changeset) do
    project_id = Ecto.Changeset.get_field(changeset, :project_id)
    data_type = Ecto.Changeset.get_field(changeset, :data_type)

    data_type != "promise_state" or
      not Repo.exists?(
        from field in ProjectField,
          where: field.project_id == ^project_id and field.data_type == "promise_state"
      )
  end

  defp promise_id_taken?(project_id, promise_id, exclude_id) do
    query =
      from item in ProjectItem,
        where:
          item.project_id == ^project_id and
            fragment("?->'promise'->>'id' = ?", item.values, ^promise_id)

    query =
      if exclude_id do
        where(query, [item], item.id != ^exclude_id)
      else
        query
      end

    Repo.exists?(query)
  end

  defp add_errors(changeset, errors) do
    Enum.reduce(errors, changeset, fn {field, messages}, changeset ->
      Enum.reduce(messages, changeset, &Ecto.Changeset.add_error(&2, field, &1))
    end)
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
