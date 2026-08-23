defmodule OpenAgentsWeb.RepositoryJSON do
  @moduledoc "JSON projections for hosted repositories."

  alias OpenAgents.Repositories.Repository

  def repository(%Repository{} = repository, permissions, base_url) do
    owner = repository.namespace.slug

    %{
      "id" => repository.id,
      "name" => repository.name,
      "full_name" => owner <> "/" <> repository.name,
      "owner" => %{
        "id" => repository.namespace.provider_account_id,
        "login" => owner,
        "type" => if(repository.namespace.kind == "user", do: "User", else: "Organization")
      },
      "private" => repository.visibility == "private",
      "visibility" => repository.visibility,
      "description" => repository.description,
      "default_branch" => repository.default_branch,
      "pull_requests_enabled" => repository.pull_requests_enabled,
      "lifecycle_state" => repository.lifecycle_state,
      "provision_error_code" => repository.provision_error_code,
      "clone_url" => base_url <> "/#{owner}/#{repository.name}.git",
      "html_url" => base_url <> "/#{owner}/#{repository.name}",
      "permissions" => permissions,
      "created_at" => DateTime.to_iso8601(repository.inserted_at),
      "updated_at" => DateTime.to_iso8601(repository.updated_at)
    }
  end

  def permissions(repository, role) do
    %{
      "admin" => role in ~w(owner maintainer),
      "push" => role in ~w(owner maintainer contributor),
      "pull" => repository.visibility == "public" or not is_nil(role)
    }
  end
end
