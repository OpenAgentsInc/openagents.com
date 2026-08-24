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
      "mirror" => Repository.mirror?(repository),
      "upstream" => upstream(repository),
      "created_at" => DateTime.to_iso8601(repository.inserted_at),
      "updated_at" => DateTime.to_iso8601(repository.updated_at)
    }
  end

  # A mirror names its upstream in the response body, not only in the
  # database. `"mirror" => false` and `"upstream" => nil` are published for
  # every owned repository too, so a reader learns the distinction exists
  # from any repository rather than only from a mirror.
  #
  # `"license"` here is what the upstream published at the moment the copy was
  # taken, or the literal `"none"`. It is a record of the upstream's terms,
  # never a claim about the copy.
  defp upstream(%Repository{upstream_url: nil}), do: nil

  defp upstream(%Repository{} = repository) do
    %{
      "url" => repository.upstream_url,
      "license" => repository.upstream_license,
      "direction" => "one_way",
      "accepts_pushes" => false
    }
  end

  # `"push"` is a claim about what the Git plane will accept, so a mirror
  # reports `false` for every role. An owner who reads `true` here and then
  # has the push refused has been told two different things by one system.
  def permissions(repository, role) do
    %{
      "admin" => role in ~w(owner maintainer),
      "push" => role in ~w(owner maintainer contributor) and not Repository.mirror?(repository),
      "pull" => repository.visibility == "public" or not is_nil(role)
    }
  end
end
