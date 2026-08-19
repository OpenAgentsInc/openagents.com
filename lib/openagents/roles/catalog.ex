defmodule OpenAgents.Roles.Catalog do
  @moduledoc "Versioned catalog of admitted and explicitly inactive Sarah role programs."

  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Roles.{CodingLieutenant, GeneralCollaborator, Role}

  @inactive_programs [
    {"sarah.role.sales_discovery.v1", "sales_discovery", ["text", "voice"], ["crm.read"]},
    {"sarah.role.company_operations.v1", "company_operations", ["text", "voice"],
     ["operations.read", "operations.write"]},
    {"sarah.role.public_broadcast.v1", "public_broadcast", ["public"], ["broadcast.publish"]}
  ]

  @spec all() :: [Role.t()]
  def all do
    [GeneralCollaborator.artifact(), CodingLieutenant.artifact()] ++
      Enum.map(@inactive_programs, &inactive_role/1)
  end

  @spec fetch(String.t()) :: {:ok, Role.t()} | {:error, :unknown_role}
  def fetch(role_id) when is_binary(role_id) do
    case Enum.find(all(), &(&1.id == role_id)) do
      nil -> {:error, :unknown_role}
      role -> {:ok, role}
    end
  end

  @spec digest() :: String.t()
  def digest do
    all()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&Map.take(&1, [:id, :version, :status, :digest]))
    |> Canonical.digest!()
  end

  defp inactive_role({id, register, surfaces, required_capabilities}) do
    content =
      "Inactive role placeholder. It cannot enter runtime composition until its surface, " <>
        "authority, product facts, tools, and containment evidence are admitted."

    source_digest = Canonical.sha256(content)

    attributes = %{
      "schema" => "sarah.role_program.v1",
      "id" => id,
      "version" => 1,
      "status" => "inactive",
      "content" => content,
      "source_ref" => "roadmap-role:" <> id,
      "source_digest" => source_digest,
      "compatibility_min" => 1,
      "compatibility_max" => 1,
      "surfaces" => surfaces,
      "required_capabilities" => required_capabilities,
      "register" => register
    }

    %Role{
      id: id,
      version: 1,
      status: "inactive",
      content: content,
      digest: Canonical.digest!(attributes),
      source_ref: attributes["source_ref"],
      source_digest: source_digest,
      compatibility_min: 1,
      compatibility_max: 1,
      surfaces: surfaces,
      required_capabilities: required_capabilities,
      register: register
    }
  end
end
