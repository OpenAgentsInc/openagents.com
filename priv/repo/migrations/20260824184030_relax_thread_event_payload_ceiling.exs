defmodule OpenAgents.Repo.Migrations.RelaxThreadEventPayloadCeiling do
  @moduledoc """
  A thread's transcript holds the work, so it cannot be capped like a projection.

  The 16 KB ceiling came from `scv_run_events`, whose payloads are deliberately
  minimal: that table reduces a payload to a fixed key allowlist and lets no
  file path, tool argument, tool output, or report prose reach a row, because
  the work itself lives elsewhere. `ComputerActivity` states the same premise
  outright — its events are a projection and never the authority.

  `thread_events` is the authority. It has to reproduce a session as a full
  ATIF trajectory, and a single reasoning block observed in a live session is
  38,791 characters. Under the inherited ceiling the only way to record that was
  to split it across events and reassemble it on read, which is a wire concern
  solved in the store, and a reader of the transcript paying for it forever.

  So the upper bound goes. The floor stays at "is a JSON object", which an event
  carrying nothing but its type satisfies, and the schema pin and the
  append-only shape are untouched.
  Boundedness moves to where it belongs — what a client sends to a model is
  bounded by the client, and what the record holds is what happened.
  """
  use Ecto.Migration

  def up do
    drop constraint(:thread_events, :thread_events_payload_bound_check)

    create constraint(:thread_events, :thread_events_payload_present_check,
             check: "octet_length(payload::text) >= 2"
           )
  end

  def down do
    drop constraint(:thread_events, :thread_events_payload_present_check)

    create constraint(:thread_events, :thread_events_payload_bound_check,
             check: "octet_length(payload::text) BETWEEN 2 AND 16384"
           )
  end
end
