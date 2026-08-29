defmodule OpenAgents.Repositories.GitHubProjection do
  @moduledoc "Projects retained GitHub authority into hosted namespaces and import snapshots."

  alias OpenAgents.{Accounts, GitHub, GitHubOAuth, Repositories}
  alias OpenAgents.Accounts.User
  alias OpenAgents.Repositories.Namespace

  @maximum_organization_pages 10

  def available_namespaces(%User{} = user) do
    with {:ok, user_namespace} <- Repositories.ensure_user_namespace(user),
         {:ok, token} <- retained_token(user),
         {:ok, organizations} <- collect_admin_organizations(token, 1, []) do
      namespaces =
        Enum.map(organizations, fn organization ->
          {:ok, namespace} =
            Repositories.upsert_github_namespace(%{
              provider_account_id: organization["id"],
              provider_node_id: organization["node_id"],
              slug: organization["login"],
              kind: "organization"
            })

          namespace
        end)

      {:ok, [user_namespace | namespaces]}
    else
      {:error, :github_token_missing} -> {:error, :github_connection_required}
      {:error, reason} -> {:error, reason}
    end
  end

  def import_candidates(%User{} = user, page \\ 1) when page in 1..1_000 do
    with {:ok, namespaces} <- available_namespaces(user),
         {:ok, token} <- retained_token(user),
         {:ok, repositories} <- GitHub.list_repository_page(token, page: page, per_page: 50) do
      namespace_ids = MapSet.new(namespaces, & &1.provider_account_id)

      items =
        Enum.filter(repositories["items"], fn repository ->
          repository["readable"] and not repository["archived"] and
            MapSet.member?(namespace_ids, repository["owner"]["id"])
        end)

      {:ok, %{repositories | "items" => items}}
    else
      {:error, :github_token_missing} -> {:error, :github_connection_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves one named owner to a namespace the caller may create repositories in.

  An owner is either a personal namespace or an organization, and the name
  alone does not say which. Deciding here is what lets a client pass along the
  owner it was given instead of guessing at the kind and picking a route on
  the guess.

  The caller's own login resolves without asking GitHub: the token already
  authenticates that identity, so a personal repository does not depend on a
  retained GitHub token the way an organization repository does. Another
  person's namespace is refused outright rather than asked about, because
  GitHub cannot answer "is this login an organization you administer" for a
  login that is a person.
  """
  def authorized_namespace(%User{} = user, requested_slug) when is_binary(requested_slug) do
    if own_login?(user, requested_slug) do
      Repositories.ensure_user_namespace(user)
    else
      user_id = user.id

      case Repositories.get_namespace_by_slug(requested_slug) do
        %Namespace{kind: "user", owner_user_id: ^user_id} = namespace ->
          {:ok, namespace}

        %Namespace{kind: "user"} ->
          {:error, :namespace_not_allowed}

        _absent_or_organization ->
          authorized_organization(user, requested_slug)
      end
    end
  end

  defp own_login?(%User{github_login: login}, requested_slug) when is_binary(login),
    do: String.downcase(login) == String.downcase(requested_slug)

  defp own_login?(_user, _requested_slug), do: false

  def authorized_organization(%User{} = user, requested_slug) when is_binary(requested_slug) do
    with {:ok, token} <- retained_token(user),
         {:ok, membership} <- find_organization_membership(token, requested_slug, 1),
         "admin" <- membership["role"] || {:error, :namespace_not_allowed},
         organization = membership["organization"],
         {:ok, namespace} <-
           Repositories.upsert_github_namespace(%{
             provider_account_id: organization["id"],
             provider_node_id: organization["node_id"],
             slug: organization["login"],
             kind: "organization"
           }) do
      {:ok, namespace}
    else
      {:error, reason} -> {:error, reason}
      _not_admin -> {:error, :namespace_not_allowed}
    end
  end

  def import_source(%User{} = user, full_name) when is_binary(full_name) do
    with {:ok, token} <- retained_token(user),
         {:ok, repository} <- GitHub.get_import_source(token, full_name),
         {:ok, references} <- GitHub.list_references(token, full_name),
         {:ok, lfs_warning?} <- lfs_warning(token, repository, references) do
      refs = Map.new(references["refs"], &{&1["name"], &1["sha"]})
      default_branch = repository["default_branch"]

      {:ok,
       %{
         provider: "github",
         source_repository_id: repository["id"],
         source_owner_id: repository["owner"]["id"],
         source_full_name: repository["full_name"],
         source_default_branch: default_branch,
         source_ref_digest: references["digest"],
         source_head_sha: refs["refs/heads/#{default_branch}"],
         source_refs: refs,
         source_uses_lfs: lfs_warning?,
         source_public: repository["private"] == false,
         source_license: repository["license"]
       }, repository}
    else
      {:error, :github_token_missing} -> {:error, :github_connection_required}
      {:error, :github_not_found} -> {:error, :source_repository_not_accessible}
      {:error, :github_permission_denied} -> {:error, :source_repository_not_accessible}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retained_token(%User{} = user) do
    # GitHub reports the union of every scope the application already holds,
    # so a returning repository grant often includes `user:email` from
    # sign-in as well as `repo` and `read:org`. Exact equality against
    # `required_scopes/0` then 403s `GET /api/v1/user` after a successful
    # connect. Presence of the required set is the contract.
    if GitHubOAuth.required_scopes_present?(user.github_token_scopes) do
      Accounts.github_token(user)
    else
      {:error, :github_scope_required}
    end
  end

  defp find_organization_membership(_token, _requested_slug, page)
       when page > @maximum_organization_pages,
       do: {:error, :namespace_not_allowed}

  defp find_organization_membership(token, requested_slug, page) do
    requested_key = String.downcase(requested_slug)

    with {:ok, result} <- GitHub.list_active_organization_memberships(token, page: page) do
      case Enum.find(result["items"], fn membership ->
             String.downcase(membership["organization"]["login"]) == requested_key
           end) do
        nil ->
          if result["has_next_page"],
            do: find_organization_membership(token, requested_slug, page + 1),
            else: {:error, :namespace_not_allowed}

        membership ->
          {:ok, membership}
      end
    end
  end

  defp collect_admin_organizations(_token, page, _acc)
       when page > @maximum_organization_pages,
       do: {:error, :github_pagination_limit_exceeded}

  defp collect_admin_organizations(token, page, acc) do
    with {:ok, result} <- GitHub.list_active_organization_memberships(token, page: page) do
      current =
        result["items"]
        |> Enum.filter(&(&1["role"] == "admin"))
        |> Enum.map(& &1["organization"])

      next_acc = acc ++ current

      if result["has_next_page"],
        do: collect_admin_organizations(token, page + 1, next_acc),
        else: {:ok, next_acc}
    end
  end

  defp lfs_warning(_token, _repository, %{"refs" => []}), do: {:ok, false}

  defp lfs_warning(token, repository, _references) do
    case GitHub.lfs_warning_inputs(token, repository["full_name"], repository["default_branch"]) do
      {:ok, inputs} -> {:ok, inputs["warning_recommended"]}
      {:error, reason} -> {:error, reason}
    end
  end
end
