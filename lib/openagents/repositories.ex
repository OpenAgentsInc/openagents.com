defmodule OpenAgents.Repositories do
  @moduledoc "Canonical repository identity and membership authorization."

  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Repo

  alias OpenAgents.Repositories.{
    IdempotencyRequest,
    Membership,
    Namespace,
    NamespaceAlias,
    ProvisioningOutbox,
    Repository,
    RepositoryImport
  }

  @initial_owner "OpenAgentsInc"
  @initial_name "openagents.com"
  @writable_roles ~w(owner maintainer contributor)

  def initial_path, do: {@initial_owner, @initial_name}

  def initial_repository! do
    get_by_path!(@initial_owner, @initial_name)
  end

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

  def get_visible_by_path!(owner, name, nil), do: get_public_by_path!(owner, name)

  def get_visible_by_path!(owner, name, %User{id: user_id}) do
    owner_key = String.downcase(owner)
    name_key = String.downcase(name)

    Repo.one!(
      from repository in repository_path_query(owner_key, name_key),
        left_join: membership in Membership,
        on: membership.repository_id == repository.id and membership.user_id == ^user_id,
        where:
          (repository.visibility == "public" and repository.lifecycle_state == "ready") or
            (not is_nil(membership.user_id) and
               membership.role in ^~w(owner maintainer contributor viewer))
    )
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

  def list_visible_repositories(%User{id: user_id}) do
    Repo.all(
      from repository in Repository,
        join: namespace in assoc(repository, :namespace),
        left_join: membership in Membership,
        on: membership.repository_id == repository.id and membership.user_id == ^user_id,
        where:
          repository.visibility == "public" or
            (not is_nil(membership.user_id) and
               membership.role in ^~w(owner maintainer contributor viewer)),
        order_by: [asc: namespace.slug_key, asc: repository.name_key, asc: repository.id],
        preload: [namespace: namespace]
    )
  end

  def list_visible_repositories_page(
        %User{id: user_id},
        per_page,
        after_cursor,
        namespace_key \\ nil
      )
      when per_page in 1..100 do
    query =
      from repository in Repository,
        join: namespace in assoc(repository, :namespace),
        left_join: membership in Membership,
        on: membership.repository_id == repository.id and membership.user_id == ^user_id,
        where:
          (repository.visibility == "public" and repository.lifecycle_state == "ready") or
            (not is_nil(membership.user_id) and
               membership.role in ^~w(owner maintainer contributor viewer)),
        order_by: [asc: namespace.slug_key, asc: repository.name_key, asc: repository.id],
        preload: [namespace: namespace]

    query =
      query
      |> apply_namespace_filter(namespace_key)
      |> apply_repository_cursor(after_cursor)

    rows = Repo.all(from row in query, limit: ^(per_page + 1))
    {Enum.take(rows, per_page), length(rows) > per_page}
  end

  defp apply_namespace_filter(query, nil), do: query

  defp apply_namespace_filter(query, namespace_key) when is_binary(namespace_key) do
    from [repository, namespace, membership] in query,
      where: namespace.slug_key == ^namespace_key
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
    %Membership{}
    |> Membership.changeset(%{repository_id: repository.id, user_id: user.id, role: role})
    |> Repo.insert(
      on_conflict: {:replace, [:role, :updated_at]},
      conflict_target: [:repository_id, :user_id],
      returning: true
    )
  end

  def ensure_initial_membership(%User{} = user) do
    add_member(initial_repository!(), user)
  end

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

  def membership_role(%Repository{id: repository_id}, %User{id: user_id}) do
    Repo.one(
      from membership in Membership,
        where: membership.repository_id == ^repository_id and membership.user_id == ^user_id,
        select: membership.role
    )
  end

  def membership_role(%Repository{}, nil), do: nil

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
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
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
    repository =
      %Repository{}
      |> Repository.creation_changeset(attrs, namespace, user.id, provisioning_kind)
      |> Repo.insert!()

    %Membership{}
    |> Membership.changeset(%{repository_id: repository.id, user_id: user.id, role: "owner"})
    |> Repo.insert!()

    repository_import =
      if source do
        %RepositoryImport{}
        |> RepositoryImport.changeset(repository.id, source)
        |> Repo.insert!()
      end

    %ProvisioningOutbox{}
    |> ProvisioningOutbox.changeset(
      repository.id,
      repository_import && repository_import.id,
      operation
    )
    |> Repo.insert!()

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
    from [repository, namespace, _membership] in query,
      where:
        namespace.slug_key > ^owner_key or
          (namespace.slug_key == ^owner_key and repository.name_key > ^name_key) or
          (namespace.slug_key == ^owner_key and repository.name_key == ^name_key and
             repository.id > ^id)
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

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
