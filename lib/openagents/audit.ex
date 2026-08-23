defmodule OpenAgents.Audit do
  @moduledoc "Records bounded security events without repository content or credentials."

  alias OpenAgents.{AuditEvent, Repo}

  @maximum_metadata_bytes 8_192

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

  defp actor_type({type, _id}) when type in ~w(user agent machine operator system), do: type

  defp actor_type({type, _id}) when type in [:user, :agent, :machine, :operator, :system],
    do: to_string(type)

  defp actor_type(:system), do: "system"

  defp actor_id({_type, nil}), do: nil
  defp actor_id({_type, id}), do: to_string(id)
  defp actor_id(:system), do: nil
end
