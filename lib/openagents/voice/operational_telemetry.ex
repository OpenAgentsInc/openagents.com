defmodule OpenAgents.Voice.OperationalTelemetry do
  @moduledoc "Emits only whitelisted, content-free voice operational telemetry."

  require Logger

  alias OpenAgents.Voice.Session

  @spec emit(atom(), Session.t(), map()) :: :ok
  def emit(event, %Session{} = session, extra \\ %{}) when is_atom(event) and is_map(extra) do
    metadata = %{
      event: Atom.to_string(event),
      session_id: session.id,
      generation: session.generation,
      status: session.status,
      model_id: session.model_id,
      voice_artifact_id: session.voice_artifact_id,
      failure_code: session.failure_code,
      event_kind: safe_string(extra[:event_kind], 128),
      disposition: safe_string(extra[:disposition], 32),
      total_tokens: safe_integer(session.usage["total_tokens"]),
      estimated_cost_microusd: safe_integer(session.usage["estimated_cost_microusd"])
    }

    :telemetry.execute([:openagents, :voice, event], %{count: 1}, metadata)

    log =
      metadata
      |> Map.put(:schema, "sarah.voice_operation.v1")
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Logger.info(["voice_operation ", Jason.encode!(log)])
    :ok
  end

  @spec admission_refused(atom()) :: :ok
  def admission_refused(reason) when is_atom(reason) do
    code =
      if reason in [
           :voice_disabled,
           :voice_draining,
           :voice_capacity_reached,
           :voice_rate_limited,
           :voice_session_in_progress,
           :text_turn_in_progress,
           :provider_rejected_call,
           :voice_connection_failed
         ],
         do: Atom.to_string(reason),
         else: "other"

    metadata = %{reason: code}
    :telemetry.execute([:openagents, :voice, :admission_refused], %{count: 1}, metadata)

    Logger.info(
      "voice_operation " <>
        Jason.encode!(%{
          schema: "sarah.voice_operation.v1",
          event: "admission_refused",
          reason: code
        })
    )

    :ok
  end

  defp safe_string(value, maximum) when is_atom(value),
    do: value |> Atom.to_string() |> String.slice(0, maximum)

  defp safe_string(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp safe_string(_value, _maximum), do: nil
  defp safe_integer(value) when is_integer(value) and value >= 0, do: value
  defp safe_integer(_value), do: 0
end
