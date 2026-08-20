defmodule OpenAgents.Incidents.Notifier do
  @moduledoc """
  Routes a recorded incident to the parties who should hear about it.

  - The **user** always gets an in-conversation signal: a broadcast on the
    conversation's incident topic, so the surface can acknowledge honestly
    ("I hit an unexpected error and logged it") instead of dead-ending.
  - The **owner/operators** get a durable operator signal for anomalous
    incidents: a broadcast on the operators topic plus a structured log line the
    incident row backs. Subscribers (an admin surface, a push channel) attach to
    these topics without changing this emitter.

  Notification never raises into the failure path that produced the incident.
  """

  alias OpenAgents.Incidents.Incident

  require Logger

  @spec route(Incident.t()) :: :ok
  def route(%Incident{} = incident) do
    notify_user(incident)
    if incident.severity == "anomalous", do: notify_operators(incident)
    :ok
  rescue
    error ->
      Logger.error("incident_notify_failed code=#{OpenAgents.OperationalLog.code(error)}")
      :ok
  end

  defp notify_user(%Incident{conversation_id: nil}), do: :ok

  defp notify_user(%Incident{conversation_id: conversation_id} = incident) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "incidents:conversation:#{conversation_id}",
      {:incident_recorded, incident_summary(incident)}
    )
  end

  defp notify_operators(%Incident{} = incident) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "incidents:operators",
      {:incident_anomalous, incident_summary(incident)}
    )

    Logger.warning(
      "incident_anomalous id=#{incident.id} code=#{incident.code} origin=#{incident.origin} " <>
        "surface=#{incident.surface} correlation=#{incident.correlation_ref}"
    )
  end

  # A bounded projection safe to put on a topic — never the raw context.
  defp incident_summary(%Incident{} = incident) do
    %{
      id: incident.id,
      code: incident.code,
      severity: incident.severity,
      origin: incident.origin,
      surface: incident.surface,
      summary: incident.summary,
      conversation_id: incident.conversation_id,
      inserted_at: incident.inserted_at
    }
  end
end
