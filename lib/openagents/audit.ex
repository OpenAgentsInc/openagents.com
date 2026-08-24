defmodule OpenAgents.Audit do
  @moduledoc "Records bounded security events without repository content or credentials."

  alias OpenAgents.{AuditEvent, Repo}

  @maximum_metadata_bytes 8_192

  # The actor kinds this application writes. `machine` is one of them: a paired
  # computer that authenticates to the Git plane pushes and fetches under
  # `{:machine, id}` (`OpenAgentsWeb.Plugs.ForgeGitAuth.principal_for/1` into
  # `OpenAgents.Forge.GitHTTP.audit_actor/1`), so the stored value is real and
  # keeps its spelling under CANON-002. `OpenAgents.Forge.GitHTTP.audit_actor_kinds/0`
  # is the list that must stay inside this one, and `OpenAgents.AuditTest`
  # asserts the containment rather than trusting a reading of the call sites.
  @actor_kinds [:user, :agent, :machine, :operator, :system]

  @doc "The actor kinds `record!/5` accepts, as strings."
  @spec actor_kinds() :: [String.t()]
  def actor_kinds, do: Enum.map(@actor_kinds, &Atom.to_string/1)

  def record!(event_type, actor, subject_type, subject_id, options \\ []) do
    metadata = Keyword.get(options, :metadata, %{})

    if is_map(metadata) and byte_size(Jason.encode!(metadata)) <= @maximum_metadata_bytes do
      %AuditEvent{}
      |> AuditEvent.changeset(%{
        event_type: event_type,
        actor_type: actor_type(actor),
        actor_id: actor_id(actor),
        subject_type: subject_type,
        subject_id: to_string(subject_id),
        repository_id: Keyword.get(options, :repository_id),
        metadata: metadata
      })
      |> Repo.insert!()
    else
      raise ArgumentError, "audit metadata is invalid"
    end
  end

  defp actor_type({type, _id}) when type in @actor_kinds, do: Atom.to_string(type)

  defp actor_type(:system), do: "system"

  defp actor_id({_type, nil}), do: nil
  defp actor_id({_type, id}), do: to_string(id)
  defp actor_id(:system), do: nil
end
