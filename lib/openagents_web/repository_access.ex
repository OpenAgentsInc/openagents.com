defmodule OpenAgentsWeb.RepositoryAccess do
  @moduledoc "Repository-aware policy for browser code and repository pages."

  alias OpenAgents.Forge.Visibility
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @member_roles ~w(owner maintainer contributor viewer)

  def get_visible!(owner, name, user) do
    owner
    |> Repositories.get_visible_by_path!(name, user)
    |> OpenAgents.Repo.preload(:repository_import)
  end

  def base(%Repository{namespace: namespace, name: name}), do: "/#{namespace.slug}/#{name}"

  def full_source?(%Repository{} = repository, user) do
    ready?(repository) and
      (member?(repository, user) or ordinary_public?(repository) or
         Visibility.allows?(repository.storage_key, :files))
  end

  def ledger?(%Repository{} = repository, user) do
    full_source?(repository, user) or
      (ready?(repository) and Visibility.allows?(repository.storage_key, :ledger))
  end

  def allows_file?(%Repository{} = repository, user, path, ref_sha, head_sha) do
    full_source?(repository, user) or
      (ready?(repository) and
         Visibility.allows_file?(repository.storage_key, path, ref_sha, head_sha))
  end

  def member?(%Repository{} = repository, user),
    do: Repositories.membership_role(repository, user) in @member_roles

  def clone_url(%Repository{} = repository) do
    OpenAgentsWeb.Endpoint.url() <>
      "/git/#{repository.namespace.slug}/#{repository.name}.git"
  end

  defp ordinary_public?(%Repository{visibility: "public", storage_key: storage_key}),
    do: storage_key not in OpenAgents.Forge.Repos.allowed_repos()

  defp ordinary_public?(_repository), do: false
  defp ready?(%Repository{lifecycle_state: "ready"}), do: true
  defp ready?(_repository), do: false
end
