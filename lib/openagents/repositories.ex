defmodule OpenAgents.Repositories do
  @moduledoc "Canonical repository identity and membership authorization."

  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.{Repos, WAL}
  alias OpenAgents.{Analytics, Audit, Repo}
  alias OpenAgents.Machines.Machine

  alias OpenAgents.Repositories.{
    IdempotencyRequest,
    MachineGrant,
    Membership,
    Namespace,
    NamespaceAlias,
    ProvisioningOutbox,
    Repository,
    RepositoryImport
  }

  @writable_roles ~w(owner maintainer contributor)
  @all_roles ~w(owner maintainer contributor viewer)
  @repository_namespace_limit 100

  # GitHub's default label set. Every created or imported repository starts
  # with this vocabulary so triage has something to attach on day one; a
  # repository that does not want a name can delete it.
  @default_labels [
    {"bug", "d73a4a", "Something isn't working"},
    {"documentation", "0075ca", "Improvements or additions to docs"},
    {"duplicate", "cfd3d7", "This issue or pull request already exists"},
    {"enhancement", "a2eeef", "New feature or request"},
    {"good first issue", "7057ff", "Good for newcomers"},
    {"help wanted", "008672", "Extra attention is needed"},
    {"invalid", "e4e669", "This doesn't seem right"},
    {"question", "d876e3", "Further information is requested"},
    {"wontfix", "ffffff", "This will not be worked on"}
  ]

  # The two durable receipts that say where a repository is in provisioning:
  # the outbox row is the work, the import row is the GitHub snapshot. Both are
  # `has_one`, so they are preloaded together wherever a surface renders
  # progress or provenance.
  @provisioning_assocs [:repository_import, :provisioning_outbox]

  def get_by_path!(owner, name) when is_binary(owner) and is_binary(name) do
    owner_key = String.downcase(owner)
    name_key = String.downcase(name)

    Repo.one!(repository_path_query(owner_key, name_key))
  end

  def get_public_by_path!(owner, name) when is_binary(owner) and is_binary(name) do
    owner_key = String.downcase(owner)
    name_key = String.downcase(name)

    Repo.one!(
      from repository in repository_path_query(owner_key, name_key),
        where: repository.visibility == "public" and repository.lifecycle_state == "ready"
    )
  end

  def get_visible_by_path!(owner, name, user) do
    owner_key = String.downcase(owner)
    name_key = String.downcase(name)

    owner_key
    |> repository_path_query(name_key)
    |> readable_by(user)
    |> Repo.one!()
  end

  @doc """
  Narrows a repository query to the repositories `user` may read.

  One predicate, composed by every surface that lists or resolves a repository,
  so a new surface cannot arrive at a looser rule by rewriting the join from
  memory. Reading is public on a repository that is both public and
  provisioned; anything else needs a membership in a reading role. `nil` is an
  anonymous visitor, who sees only the public half.

  It composes into a query that already carries joins and preloads: the
  membership join is appended, so the caller's own bindings keep their
  positions.
  """
  def readable_by(query, user)

  def readable_by(query, nil) do
    from repository in query,
      where: repository.visibility == "public" and repository.lifecycle_state == "ready"
  end

  def readable_by(query, %User{id: user_id}) do
    from repository in query,
      left_join: reader in Membership,
      on: reader.repository_id == repository.id and reader.user_id == ^user_id,
      where:
        (repository.visibility == "public" and repository.lifecycle_state == "ready") or
          (not is_nil(reader.user_id) and reader.role in ^@all_roles)
  end

  def get_writable_by_path!(owner, name, %User{id: user_id}) do
    owner_key = String.downcase(owner)
    name_key = String.downcase(name)

    Repo.one!(
      from repository in repository_path_query(owner_key, name_key),
        join: membership in Membership,
        on:
          membership.repository_id == repository.id and membership.user_id == ^user_id and
            membership.role in ^@writable_roles,
        join: user in User,
        on: user.id == membership.user_id and user.status == "active",
        where: repository.lifecycle_state == "ready"
    )
  end

  def create_repository(attrs) do
    owner = fetch_attr!(attrs, :owner)

    Repo.transaction(fn ->
      namespace = ensure_legacy_namespace!(owner)
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.new()
        |> Map.put(:namespace_id, namespace.id)
        |> Map.put_new(:storage_key, Ecto.UUID.generate())
        |> Map.put_new(:lifecycle_state, "ready")
        |> Map.put_new(:provisioning_kind, "empty")
        |> Map.put_new(:ready_at, now)

      %Repository{}
      |> Repository.changeset(attrs)
      |> Repo.insert!()
      |> Repo.preload(:namespace)
    end)
    |> case do
      {:ok, repository} -> {:ok, repository}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  def ensure_user_namespace(%User{} = user) do
    upsert_github_namespace(%{
      provider_account_id: user.github_id,
      slug: user.github_login,
      kind: "user",
      owner_user_id: user.id
    })
  end

  def upsert_github_namespace(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :provider_refreshed_at, DateTime.utc_now())

    Repo.transaction(fn ->
      provider_account_id = fetch_attr!(attrs, :provider_account_id)
      kind = fetch_attr!(attrs, :kind)

      existing =
        Repo.one(
          from namespace in Namespace,
            where:
              namespace.provider == "github" and
                namespace.provider_account_id == ^provider_account_id and
                namespace.kind == ^kind,
            lock: "FOR UPDATE"
        )

      case existing do
        nil ->
          %Namespace{}
          |> Namespace.changeset(attrs)
          |> Repo.insert!()

        %Namespace{} = namespace ->
          maybe_update_namespace!(namespace, attrs)
      end
    end)
    |> unwrap_transaction()
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  def get_namespace_by_slug!(slug) when is_binary(slug) do
    slug_key = String.downcase(slug)

    case Repo.get_by(Namespace, slug_key: slug_key, state: "active") do
      %Namespace{} = namespace ->
        namespace

      nil ->
        Repo.one!(
          from namespace_alias in NamespaceAlias,
            join: namespace in assoc(namespace_alias, :namespace),
            where: namespace_alias.slug_key == ^slug_key and namespace.state == "active",
            select: namespace
        )
    end
  end

  def create_user_repository(%User{} = user, attrs, idempotency_key)
      when is_map(attrs) and is_binary(idempotency_key) do
    with {:ok, namespace} <- ensure_user_namespace(user) do
      create_repository_transaction(
        user,
        namespace,
        attrs,
        nil,
        "create",
        "empty",
        idempotency_key
      )
    end
  end

  def create_organization_repository(
        %User{} = user,
        %Namespace{kind: "organization"} = namespace,
        attrs,
        idempotency_key
      )
      when is_map(attrs) and is_binary(idempotency_key) do
    create_repository_transaction(
      user,
      namespace,
      attrs,
      nil,
      "create",
      "empty",
      idempotency_key
    )
  end

  def create_user_import(%User{} = user, source, attrs, idempotency_key)
      when is_map(source) and is_map(attrs) and is_binary(idempotency_key) do
    with {:ok, namespace} <- ensure_user_namespace(user),
         true <-
           fetch_attr!(source, :source_owner_id) == user.github_id or
             {:error, :source_namespace_mismatch} do
      create_repository_transaction(
        user,
        namespace,
        attrs,
        source,
        "github_import",
        "github_import",
        idempotency_key
      )
    end
  end

  def create_organization_import(
        %User{} = user,
        %Namespace{kind: "organization"} = namespace,
        source,
        attrs,
        idempotency_key
      )
      when is_map(source) and is_map(attrs) and is_binary(idempotency_key) do
    if fetch_attr!(source, :source_owner_id) == namespace.provider_account_id do
      create_repository_transaction(
        user,
        namespace,
        attrs,
        source,
        "github_import",
        "github_import",
        idempotency_key
      )
    else
      {:error, :source_namespace_mismatch}
    end
  end

  def list_visible_repositories(%User{} = user) do
    Repo.all(
      from repository in readable_by(Repository, user),
        join: namespace in assoc(repository, :namespace),
        order_by: [asc: namespace.slug_key, asc: repository.name_key, asc: repository.id],
        preload: [namespace: namespace]
    )
  end

  @doc """
  Whether `user` can read any repository at all.

  What a workspace-wide list asks to tell an empty page from an empty
  workspace: "no open issues" and "no repositories yet" want different words
  and different next steps, and only this distinguishes them.
  """
  def any_visible_repository?(user), do: Repo.exists?(readable_by(Repository, user))

  @doc "Delete a repository owned by `user`, including its durable and node-local Git data."
  def delete_owned_repository(owner, name, %User{} = user, options \\ [])
      when is_binary(owner) and is_binary(name) do
    with %Repository{} = repository <- owned_repository(owner, name, user) do
      result =
        :global.trans({{:forge_push, repository.storage_key}, self()}, fn ->
          delete_owned_repository_locked(repository, user)
        end)

      case result do
        {:ok, deleted} = success ->
          broadcast_repository_change(deleted.id)

          Analytics.capture("repository_deleted", Analytics.distinct_id(user), %{
            "repository_id" => deleted.id,
            "provisioning_kind" => deleted.provisioning_kind,
            "surface" => Keyword.get(options, :surface, "api")
          })

          success

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
    end
  end

  defp owned_repository(owner, name, %User{id: user_id}) do
    owner_key = String.downcase(owner)
    name_key = String.downcase(name)

    Repo.one(
      from repository in repository_path_query(owner_key, name_key),
        join: membership in Membership,
        on:
          membership.repository_id == repository.id and membership.user_id == ^user_id and
            membership.role == "owner"
    )
  end

  defp delete_owned_repository_locked(repository, user) do
    Repo.transaction(fn ->
      locked_repository =
        Repo.one(
          from candidate in Repository,
            join: membership in Membership,
            on:
              membership.repository_id == candidate.id and membership.user_id == ^user.id and
                membership.role == "owner",
            where: candidate.id == ^repository.id,
            lock: "FOR UPDATE",
            select: candidate
        )

      if is_nil(locked_repository), do: Repo.rollback(:not_found)

      provisioning =
        Repo.one(
          from outbox in ProvisioningOutbox,
            where: outbox.repository_id == ^locked_repository.id,
            lock: "FOR UPDATE"
        )

      if provisioning && provisioning.state == "running", do: Repo.rollback(:repository_busy)

      with :ok <- WAL.delete_repo(locked_repository.storage_key),
           :ok <- delete_local_caches(locked_repository.storage_key) do
        Audit.record!(
          "repository.deleted",
          {:user, user.id},
          "repository",
          locked_repository.id,
          repository_id: locked_repository.id,
          metadata: %{
            "owner" => locked_repository.owner,
            "name" => locked_repository.name,
            "provisioning_kind" => locked_repository.provisioning_kind
          }
        )

        Repo.delete!(locked_repository)
      else
        {:error, reason} -> Repo.rollback({:storage_cleanup_failed, reason})
      end
    end)
  end

  defp delete_local_caches(storage_key) do
    [node() | Node.list()]
    |> Enum.uniq()
    |> Task.async_stream(
      fn target ->
        if target == node() do
          Repos.delete_repo(storage_key)
        else
          :erpc.call(target, Repos, :delete_repo, [storage_key], 30_000)
        end
      end,
      ordered: false,
      timeout: 31_000,
      on_timeout: :kill_task,
      max_concurrency: max(1, 1 + length(Node.list()))
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, reason}}
      {:exit, reason}, :ok -> {:halt, {:error, reason}}
    end)
  end

  def list_visible_repositories_page(
        %User{} = user,
        per_page,
        after_cursor,
        namespace_key \\ nil
      )
      when per_page in 1..100 do
    query =
      from repository in readable_by(Repository, user),
        join: namespace in assoc(repository, :namespace),
        as: :namespace,
        order_by: [asc: namespace.slug_key, asc: repository.name_key, asc: repository.id],
        preload: [namespace: namespace]

    query =
      query
      |> apply_namespace_filter(namespace_key)
      |> apply_repository_cursor(after_cursor)

    rows =
      from(row in query, limit: ^(per_page + 1))
      |> Repo.all()
      |> Repo.preload(@provisioning_assocs)

    {Enum.take(rows, per_page), length(rows) > per_page}
  end

  @doc """
  One repository the user may see, by id, with its provisioning receipts.

  The list page's per-row counterpart: a surface that has already rendered a
  row and then hears the repository changed reloads exactly that row rather
  than the whole page. Returns `nil` rather than raising, because a repository
  can stop being visible between the broadcast and the read.
  """
  def get_visible_repository(id, user) when is_binary(id) do
    visible_repository(
      from repository in readable_by(Repository, user),
        join: namespace in assoc(repository, :namespace),
        where: repository.id == ^id,
        preload: [namespace: namespace]
    )
  end

  defp visible_repository(query) do
    case Repo.one(query) do
      nil -> nil
      %Repository{} = repository -> Repo.preload(repository, @provisioning_assocs)
    end
  end

  @doc """
  Subscribes the caller to one repository's provisioning transitions.

  DATA-001: PostgreSQL stays authoritative. The message carries the repository
  id and nothing else, so a subscriber re-reads through its own visibility
  predicate and can never be handed a row the database would not have given it.
  """
  def subscribe_provisioning(repository_id) when is_binary(repository_id),
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, provisioning_topic(repository_id))

  @doc "Subscribes a repository index to repository creation and deletion events."
  def subscribe_repository_changes,
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, repository_changes_topic())

  @doc "Stops the caller hearing about one repository, once it has settled."
  def unsubscribe_provisioning(repository_id) when is_binary(repository_id),
    do: Phoenix.PubSub.unsubscribe(OpenAgents.PubSub, provisioning_topic(repository_id))

  @doc """
  Announces that one repository's provisioning or import state moved.

  Called after the owning transaction commits, never inside it: a subscriber
  re-reads immediately, and a message sent from inside the transaction races
  the commit and hands it the old row.
  """
  def broadcast_provisioning(repository_id) when is_binary(repository_id) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      provisioning_topic(repository_id),
      {:repository_provisioning, repository_id}
    )
  end

  @doc "Announces that a repository entered or left the visible repository collection."
  def broadcast_repository_change(repository_id) when is_binary(repository_id) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      repository_changes_topic(),
      {:repository_changed, repository_id}
    )
  end

  @doc "Records accepted Git activity and refreshes repository-list subscribers."
  def record_push_activity(storage_key, occurred_at \\ DateTime.utc_now())
      when is_binary(storage_key) do
    case Repo.update_all(
           from(repository in Repository,
             where: repository.storage_key == ^storage_key,
             select: repository.id
           ),
           set: [updated_at: occurred_at]
         ) do
      {1, [repository_id]} ->
        broadcast_repository_change(repository_id)
        :ok

      {0, []} ->
        {:error, :repository_not_found}
    end
  end

  defp provisioning_topic(repository_id), do: "repository:" <> repository_id
  defp repository_changes_topic, do: "repositories:changes"

  defp apply_namespace_filter(query, nil), do: query

  defp apply_namespace_filter(query, namespace_key) when is_binary(namespace_key) do
    where(query, [namespace: namespace], namespace.slug_key == ^namespace_key)
  end

  def get_import_for_user!(id, %User{id: user_id}) do
    Repo.one!(
      from repository_import in RepositoryImport,
        join: repository in assoc(repository_import, :repository),
        join: membership in Membership,
        on: membership.repository_id == repository.id and membership.user_id == ^user_id,
        where: repository_import.id == ^id,
        preload: [repository: {repository, [:namespace]}]
    )
  end

  def add_member(%Repository{} = repository, %User{} = user, role \\ "contributor") do
    Repo.transaction(fn ->
      membership =
        %Membership{}
        |> Membership.changeset(%{repository_id: repository.id, user_id: user.id, role: role})
        |> Repo.insert!(
          on_conflict: {:replace, [:role, :updated_at]},
          conflict_target: [:repository_id, :user_id],
          returning: true
        )

      Audit.record!(
        "repository.membership.updated",
        {:user, user.id},
        "membership",
        membership_subject_id(membership),
        repository_id: repository.id,
        metadata: %{"role" => membership.role}
      )

      membership
    end)
  end

  @doc """
  Lists one repository's members with their users, owners first.

  The order is role rank and then login, so the page reads the same way every
  time it renders.
  """
  def list_members(%Repository{id: repository_id}) do
    from(membership in Membership,
      join: user in assoc(membership, :user),
      where: membership.repository_id == ^repository_id,
      order_by: [
        asc:
          fragment(
            "array_position(array['owner','maintainer','contributor','viewer'], ?)",
            membership.role
          ),
        asc: fragment("lower(?)", user.github_login)
      ],
      preload: [user: user]
    )
    |> Repo.all()
  end

  @doc "The acting owner's view of one member row: add by GitHub login."
  def add_member_by_login(%Repository{} = repository, %User{} = actor, login, role)
      when is_binary(login) and role in @all_roles do
    with_owner_memberships(repository, actor, fn _memberships ->
      case active_user_by_login(login) do
        %User{} = user ->
          membership = upsert_membership!(repository, user, role)
          audit_membership(repository, actor, user, "added", role)
          membership

        nil ->
          Repo.rollback(:unknown_user)
      end
    end)
  end

  def change_member_role(%Repository{} = repository, %User{} = actor, user_id, role)
      when role in @all_roles do
    with_owner_memberships(repository, actor, fn memberships ->
      user = Repo.get(User, user_id)
      membership = Enum.find(memberships, &(&1.user_id == user_id))

      if is_nil(user) or is_nil(membership), do: Repo.rollback(:unknown_member)
      guard_last_owner!(memberships, membership, role)

      updated = upsert_membership!(repository, user, role)
      audit_membership(repository, actor, user, "role changed", role)
      updated
    end)
  end

  def remove_member(%Repository{} = repository, %User{} = actor, user_id) do
    case with_owner_memberships(repository, actor, fn memberships ->
           user = Repo.get(User, user_id)
           membership = Enum.find(memberships, &(&1.user_id == user_id))

           if is_nil(user) or is_nil(membership), do: Repo.rollback(:unknown_member)
           guard_last_owner!(memberships, membership, nil)
           Repo.delete!(membership)

           Audit.record!(
             "repository.membership.removed",
             {:user, actor.id},
             "membership",
             membership_subject_id(membership),
             repository_id: repository.id,
             metadata: %{"login" => user.github_login}
           )

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Serialize membership administration per repository. This makes both the
  # owner check and the last-owner rule true at the instant of the write, even
  # when an owner keeps an old LiveView open or two owners act concurrently.
  defp with_owner_memberships(%Repository{id: repository_id}, %User{id: actor_id}, operation) do
    Repo.transaction(fn ->
      memberships =
        Repo.all(
          from membership in Membership,
            where: membership.repository_id == ^repository_id,
            order_by: [asc: membership.user_id],
            lock: "FOR UPDATE"
        )

      active_actor? =
        Repo.exists?(
          from user in User,
            where: user.id == ^actor_id and user.status == "active"
        )

      actor_owns? =
        Enum.any?(memberships, &(&1.user_id == actor_id and &1.role == "owner"))

      if active_actor? and actor_owns? do
        operation.(memberships)
      else
        Repo.rollback(:forbidden)
      end
    end)
  end

  # A repository with no owner cannot be administered any more, so the last
  # owner cannot be demoted or removed, including by themselves. The caller
  # holds row locks over every membership in this repository.
  defp guard_last_owner!(memberships, %Membership{} = membership, new_role) do
    leaving_owner? = membership.role == "owner" and new_role != "owner"
    owner_count = Enum.count(memberships, &(&1.role == "owner"))

    if leaving_owner? and owner_count <= 1, do: Repo.rollback(:last_owner)
  end

  defp upsert_membership!(repository, user, role) do
    %Membership{}
    |> Membership.changeset(%{
      repository_id: repository.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:role, :updated_at]},
      conflict_target: [:repository_id, :user_id],
      returning: true
    )
  end

  defp audit_membership(repository, actor, subject, action, role) do
    Audit.record!(
      "repository.membership.updated",
      {:user, actor.id},
      "membership",
      "#{repository.id}:#{subject.id}",
      repository_id: repository.id,
      metadata: %{"action" => action, "role" => role, "login" => subject.github_login}
    )
  end

  defp active_user_by_login(login) do
    Repo.one(
      from user in User,
        where:
          user.status == "active" and
            fragment("lower(?)", user.github_login) == ^String.downcase(String.trim(login))
    )
  end

  def grant_machine(%Repository{} = repository, %User{} = actor, %Machine{} = machine, operations)
      when is_list(operations) do
    with true <- machine.user_id == actor.id or {:error, :machine_not_owned},
         role when role in ~w(owner maintainer) <- membership_role(repository, actor) do
      Repo.transaction(fn ->
        grant =
          %MachineGrant{}
          |> MachineGrant.changeset(%{
            repository_id: repository.id,
            machine_id: machine.id,
            created_by_user_id: actor.id,
            operations: operations |> Enum.uniq() |> Enum.sort()
          })
          |> Repo.insert!(
            on_conflict: {:replace, [:operations, :created_by_user_id, :updated_at]},
            conflict_target: [:repository_id, :machine_id],
            returning: true
          )

        Audit.record!(
          "repository.machine_grant.updated",
          {:user, actor.id},
          "machine_grant",
          grant.id,
          repository_id: repository.id,
          metadata: %{"machine_id" => machine.id, "operations" => grant.operations}
        )

        grant
      end)
    else
      nil -> {:error, :repository_not_allowed}
      false -> {:error, :machine_not_owned}
      {:error, reason} -> {:error, reason}
      _role -> {:error, :repository_not_allowed}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  def machine_access?(%Repository{id: repository_id}, machine_id, operation)
      when operation in ~w(read write) and is_binary(machine_id) do
    now = DateTime.utc_now()

    Repo.exists?(
      from grant in MachineGrant,
        join: machine in Machine,
        on:
          machine.id == grant.machine_id and machine.status == "active" and
            machine.token_expires_at > ^now,
        where:
          grant.repository_id == ^repository_id and grant.machine_id == ^machine_id and
            fragment("? = ANY(?)", ^operation, grant.operations)
    )
  end

  def machine_access?(%Repository{}, _machine_id, _operation), do: false

  def writable?(%Repository{id: repository_id}, %User{id: user_id}) do
    Repo.exists?(
      from membership in Membership,
        join: user in User,
        on: user.id == membership.user_id and user.status == "active",
        where:
          membership.repository_id == ^repository_id and membership.user_id == ^user_id and
            membership.role in ^@writable_roles
    )
  end

  def writable?(%Repository{}, nil), do: false

  def membership_role(%Repository{id: repository_id}, %User{id: user_id}) do
    Repo.one(
      from membership in Membership,
        where: membership.repository_id == ^repository_id and membership.user_id == ^user_id,
        select: membership.role
    )
  end

  def membership_role(%Repository{}, nil), do: nil

  @doc "Whether the repository is publicly readable."
  def public?(%Repository{visibility: "public"}), do: true
  def public?(%Repository{}), do: false

  @doc """
  Whether the user holds any membership role, including read-only `viewer`.
  """
  def member?(%Repository{id: repository_id}, %User{id: user_id}) do
    Repo.exists?(
      from membership in Membership,
        join: user in User,
        on: user.id == membership.user_id and user.status == "active",
        where: membership.repository_id == ^repository_id and membership.user_id == ^user_id
    )
  end

  def member?(%Repository{}, nil), do: false

  @doc """
  Whether the user may take part in issue conversations: open issues and
  comment.

  GitHub's model, which is ours: an active signed-in person can join the
  conversation on any public repository without membership; a private
  repository admits its own members. Triage writes (label, assign, close,
  edit) stay behind writability and are not governed by this predicate.
  """
  def issue_participant?(%Repository{}, nil), do: false

  def issue_participant?(%Repository{} = repository, %User{} = user) do
    active_user?(user) and (public?(repository) or member?(repository, user))
  end

  @doc "Whether the user holds the repository's `owner` role."
  def owner?(%Repository{} = repository, %User{} = user) do
    active_user?(user) and membership_role(repository, user) == "owner"
  end

  def owner?(%Repository{}, nil), do: false

  defp active_user?(%User{id: user_id}) do
    Repo.exists?(from user in User, where: user.id == ^user_id and user.status == "active")
  end

  @doc "Subscribes the caller to one repository's issue activity."
  @all_issues_topic "issues:all"

  def subscribe_issues(repository_id),
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, issues_topic(repository_id))

  def unsubscribe_issues(repository_id),
    do: Phoenix.PubSub.unsubscribe(OpenAgents.PubSub, issues_topic(repository_id))

  @doc """
  Announces that one repository's issues moved.

  Called after the owning transaction commits. The message carries the
  repository id and nothing else, so every subscriber re-reads through its own
  visibility and authorization predicates.
  """
  def broadcast_issues(repository_id) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      issues_topic(repository_id),
      {:issues_changed, repository_id}
    )

    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      @all_issues_topic,
      {:issues_changed, repository_id}
    )
  end

  defp issues_topic(repository_id), do: "issues:" <> repository_id

  @doc "Receives `{:issues_changed, repository_id}` for every repository at once."
  def subscribe_all_issues,
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, @all_issues_topic)

  @doc "Seeds GitHub's default label vocabulary onto a new or imported repository."
  def seed_default_labels!(%Repository{} = repository) do
    Enum.each(@default_labels, fn {name, color, description} ->
      Repo.insert!(
        %OpenAgents.Labels.Label{}
        |> OpenAgents.Labels.Label.changeset(%{
          name: name,
          color: color,
          description: description,
          repository_id: repository.id
        }),
        on_conflict: :nothing,
        conflict_target: [:repository_id, :name]
      )
    end)

    :ok
  end

  def list_assignable_users(%Repository{id: repository_id}) do
    Repo.all(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          membership.repository_id == ^repository_id and
            membership.role in ^@writable_roles and user.status == "active",
        order_by: [asc: fragment("lower(?)", user.github_login)]
    )
  end

  def get_assignable_user_by_login!(%Repository{id: repository_id}, login)
      when is_binary(login) do
    Repo.one!(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          membership.repository_id == ^repository_id and
            membership.role in ^@writable_roles and user.status == "active" and
            fragment("lower(?)", user.github_login) == ^String.downcase(URI.decode(login))
    )
  end

  defp create_repository_transaction(
         user,
         namespace,
         attrs,
         source,
         operation,
         provisioning_kind,
         idempotency_key
       ) do
    normalized_request = %{
      namespace_id: namespace.id,
      repository: normalize_repository_attrs(attrs),
      source: normalize_source(source)
    }

    request_digest = digest(normalized_request)

    result =
      Repo.transaction(fn ->
        case get_idempotency_request(user.id, operation, idempotency_key) do
          %IdempotencyRequest{request_digest: ^request_digest} = request ->
            replay_result(request, operation)

          %IdempotencyRequest{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            create_repository_rows!(
              user,
              namespace,
              normalized_request.repository,
              normalized_request.source,
              operation,
              provisioning_kind,
              idempotency_key,
              request_digest
            )
        end
      end)

    case result do
      {:ok, {:ok, %Repository{} = repository, :created} = value} ->
        broadcast_repository_change(repository.id)
        value

      {:ok, {:ok, %Repository{} = repository, %RepositoryImport{}, :created} = value} ->
        broadcast_repository_change(repository.id)
        value

      {:ok, value} ->
        value

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp create_repository_rows!(
         user,
         namespace,
         attrs,
         source,
         operation,
         provisioning_kind,
         idempotency_key,
         request_digest
       ) do
    lock_and_validate_quota!(namespace.id)

    repository =
      %Repository{}
      |> Repository.creation_changeset(attrs, namespace, user.id, provisioning_kind)
      |> Repo.insert!()

    Audit.record!("repository.created", {:user, user.id}, "repository", repository.id,
      repository_id: repository.id,
      metadata: %{
        "namespace_id" => namespace.id,
        "provisioning_kind" => provisioning_kind,
        "visibility" => repository.visibility
      }
    )

    membership =
      %Membership{}
      |> Membership.changeset(%{repository_id: repository.id, user_id: user.id, role: "owner"})
      |> Repo.insert!()

    Audit.record!(
      "repository.membership.created",
      {:user, user.id},
      "membership",
      membership_subject_id(membership),
      repository_id: repository.id,
      metadata: %{"role" => "owner"}
    )

    seed_default_labels!(repository)

    repository_import =
      if source do
        created_import =
          %RepositoryImport{}
          |> RepositoryImport.changeset(repository.id, source)
          |> Repo.insert!()

        Audit.record!(
          "repository.import.created",
          {:user, user.id},
          "repository_import",
          created_import.id,
          repository_id: repository.id,
          metadata: %{
            "provider" => created_import.provider,
            "source_repository_id" => created_import.source_repository_id
          }
        )

        created_import
      end

    outbox =
      %ProvisioningOutbox{}
      |> ProvisioningOutbox.changeset(
        repository.id,
        repository_import && repository_import.id,
        operation
      )
      |> Repo.insert!()

    Audit.record!(
      "repository.provisioning.pending",
      {:user, user.id},
      "provisioning_outbox",
      outbox.id,
      repository_id: repository.id,
      metadata: %{"operation" => operation}
    )

    %IdempotencyRequest{}
    |> IdempotencyRequest.changeset(
      user.id,
      operation,
      idempotency_key,
      request_digest,
      %{
        repository_id: repository.id,
        repository_import_id: repository_import && repository_import.id
      }
    )
    |> Repo.insert!()

    repository = Repo.preload(repository, [:namespace, :memberships, :repository_import])

    if repository_import do
      {:ok, repository, repository.repository_import, :created}
    else
      {:ok, repository, :created}
    end
  end

  defp replay_result(request, "github_import") do
    repository =
      Repository
      |> Repo.get!(request.repository_id)
      |> Repo.preload([:namespace, :memberships, :repository_import])

    {:ok, repository, repository.repository_import, :replayed}
  end

  defp replay_result(request, _operation) do
    repository =
      Repository
      |> Repo.get!(request.repository_id)
      |> Repo.preload([:namespace, :memberships, :repository_import])

    {:ok, repository, :replayed}
  end

  defp get_idempotency_request(user_id, operation, idempotency_key) do
    Repo.one(
      from request in IdempotencyRequest,
        where:
          request.user_id == ^user_id and request.operation == ^operation and
            request.idempotency_key == ^idempotency_key,
        lock: "FOR UPDATE"
    )
  end

  defp maybe_update_namespace!(namespace, attrs) do
    next_slug = fetch_attr!(attrs, :slug)

    if String.downcase(next_slug) != namespace.slug_key do
      assert_namespace_slug_available!(next_slug, namespace.id)

      %NamespaceAlias{}
      |> NamespaceAlias.changeset(namespace.id, namespace.slug)
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:slug_key])
    end

    namespace
    |> Namespace.changeset(attrs)
    |> Repo.update!()
  end

  # Legacy domain tests create already-ready repositories without a GitHub
  # principal. Keep that fixture seam separate from the public creation API,
  # which always projects an immutable GitHub account ID.
  defp ensure_legacy_namespace!(owner) do
    slug_key = String.downcase(owner)

    case Repo.get_by(Namespace, slug_key: slug_key, state: "active") do
      %Namespace{} = namespace ->
        namespace

      nil ->
        provider_account_id = 8_000_000_000 + :erlang.phash2(slug_key, 1_000_000_000)

        %Namespace{}
        |> Namespace.changeset(%{
          provider_account_id: provider_account_id,
          slug: owner,
          kind: "organization",
          provider_refreshed_at: DateTime.utc_now()
        })
        |> Repo.insert!()
    end
  end

  defp assert_namespace_slug_available!(slug, namespace_id) do
    slug_key = String.downcase(slug)

    collision? =
      Repo.exists?(
        from namespace in Namespace,
          where:
            namespace.slug_key == ^slug_key and namespace.state == "active" and
              namespace.id != ^namespace_id
      ) or
        Repo.exists?(
          from namespace_alias in NamespaceAlias,
            where:
              namespace_alias.slug_key == ^slug_key and
                namespace_alias.namespace_id != ^namespace_id
        )

    if collision?, do: Repo.rollback(:namespace_slug_conflict), else: :ok
  end

  defp lock_and_validate_quota!(namespace_id) do
    _namespace =
      Repo.one!(
        from namespace in Namespace, where: namespace.id == ^namespace_id, lock: "FOR UPDATE"
      )

    repository_count =
      Repo.aggregate(
        from(repository in Repository, where: repository.namespace_id == ^namespace_id),
        :count
      )

    if repository_count >= repository_namespace_limit(),
      do: Repo.rollback(:repository_quota_exceeded)
  end

  defp repository_namespace_limit do
    case Application.get_env(
           :openagents,
           :repository_namespace_limit,
           @repository_namespace_limit
         ) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @repository_namespace_limit
    end
  end

  defp repository_path_query(owner_key, name_key) do
    from repository in Repository,
      join: namespace in assoc(repository, :namespace),
      left_join: namespace_alias in NamespaceAlias,
      on: namespace_alias.namespace_id == namespace.id and namespace_alias.slug_key == ^owner_key,
      where:
        repository.name_key == ^name_key and namespace.state == "active" and
          (namespace.slug_key == ^owner_key or not is_nil(namespace_alias.id)),
      distinct: repository.id,
      preload: [namespace: namespace]
  end

  defp apply_repository_cursor(query, nil), do: query

  defp apply_repository_cursor(query, {owner_key, name_key, id}) do
    where(
      query,
      [repository, namespace: namespace],
      namespace.slug_key > ^owner_key or
        (namespace.slug_key == ^owner_key and repository.name_key > ^name_key) or
        (namespace.slug_key == ^owner_key and repository.name_key == ^name_key and
           repository.id > ^id)
    )
  end

  defp normalize_repository_attrs(attrs) do
    %{
      name: fetch_attr!(attrs, :name),
      description: fetch_attr(attrs, :description),
      visibility: fetch_attr(attrs, :visibility) || "private",
      default_branch: fetch_attr(attrs, :default_branch) || "main"
    }
  end

  defp normalize_source(nil), do: nil

  defp normalize_source(source) do
    %{
      provider: fetch_attr(source, :provider) || "github",
      source_repository_id: fetch_attr!(source, :source_repository_id),
      source_owner_id: fetch_attr!(source, :source_owner_id),
      source_full_name: fetch_attr!(source, :source_full_name),
      source_default_branch: fetch_attr!(source, :source_default_branch),
      source_ref_digest: fetch_attr!(source, :source_ref_digest),
      source_head_sha: fetch_attr(source, :source_head_sha),
      source_refs: fetch_attr!(source, :source_refs),
      source_uses_lfs: fetch_attr(source, :source_uses_lfs) || false
    }
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp fetch_attr!(attrs, key) do
    case fetch_attr(attrs, key) do
      nil -> raise ArgumentError, "missing #{key}"
      value -> value
    end
  end

  defp membership_subject_id(membership),
    do: "#{membership.repository_id}:#{membership.user_id}"

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
