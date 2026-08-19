defmodule OpenAgents.Roles.GeneralCollaborator do
  @moduledoc "The only role program admitted by the initial public application."

  @behaviour OpenAgents.Roles.Role

  alias OpenAgents.Roles.Role
  alias OpenAgents.Provenance.Canonical

  @id "sarah.role.general_collaborator.v1"
  @version 1
  @status "admitted"
  @source_ref "release-artifact:sarah.role.general_collaborator.v1"
  @compatibility_min 1
  @compatibility_max 1
  @surfaces ["text", "voice"]
  @required_capabilities []
  @register "ordinary_collaboration"
  @content """
  Work as the person's expert peer and general collaborator. Understand the
  actual question, give the answer or decision first, preserve important nuance,
  and offer the smallest useful next action. Ask one concrete question only when
  it is necessary to proceed.

  Do not silently enter sales, company-operations, coding-agent, or public-broadcast
  mode. Those require separately admitted roles and capabilities. Never pressure
  the person toward a sale, and do not use military framing in ordinary chat.
  """
  @admitted_digest "920c9d3ea657ecd08337755350e69a71805fee2a6282f30526c75dbcba59b813"

  @impl true
  def artifact do
    content = String.trim(@content)
    digest = calculated_digest()

    if digest != @admitted_digest do
      raise ArgumentError, "general collaborator role digest is not admitted"
    end

    %Role{
      id: @id,
      version: @version,
      status: @status,
      content: content,
      digest: digest,
      source_ref: @source_ref,
      source_digest: source_digest(),
      compatibility_min: @compatibility_min,
      compatibility_max: @compatibility_max,
      surfaces: @surfaces,
      required_capabilities: @required_capabilities,
      register: @register
    }
  end

  @doc false
  def calculated_digest do
    Canonical.digest!(%{
      "schema" => "sarah.role_program.v1",
      "id" => @id,
      "version" => @version,
      "status" => @status,
      "content" => String.trim(@content),
      "source_ref" => @source_ref,
      "source_digest" => source_digest(),
      "compatibility_min" => @compatibility_min,
      "compatibility_max" => @compatibility_max,
      "surfaces" => @surfaces,
      "required_capabilities" => @required_capabilities,
      "register" => @register
    })
  end

  defp source_digest, do: calculate_digest(String.trim(@content))

  @doc false
  def calculate_digest(content) when is_binary(content) do
    content
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
