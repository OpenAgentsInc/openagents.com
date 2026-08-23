defmodule OpenAgents.Incidents.Triage do
  @moduledoc """
  Typed classifier for failure reasons — never ad-hoc string matching for the
  decision itself, only exact-code lookups over a modeled table.

  - `expected`  — the user or the world caused it (cancelled, computer offline,
    an agent at capacity). State it plainly; do not escalate.
  - `degraded`  — a transient, usually-retryable fault (a provider hiccup,
    a task exit, a transport drop). Record it; escalate only on recurrence.
  - `anomalous` — a fault Sarah should not have hit, or any code this table does
    not recognize. Open an incident and notify.

  Defaulting the unknown to `anomalous` is deliberate: a failure mode we did not
  foresee is exactly the one worth surfacing.
  """

  @expected MapSet.new(~w(
    cancelled
    missing_terminal_event
    machine_offline
    machine_not_found
    ambiguous_machine
    agent_not_available
    rate_limited
    turn_in_progress
    owner_not_signed_in
    delegation_refused
    delegation_cancelled
  ))

  @degraded MapSet.new(~w(
    provider_timeout
    provider_failure
    provider_error
    turn_timeout
    machine_disconnected
    machine_timeout
    machine_revoked
    runtime_restarted
    delegation_timeout
    task_exit
    transport
    provider_task_exited
  ))

  @doc "Classify a failure code into a severity tier."
  @spec classify(String.t() | atom() | nil) :: String.t()
  def classify(code) when is_atom(code) and not is_nil(code), do: classify(Atom.to_string(code))

  def classify(code) when is_binary(code) do
    # A code may be `family:detail`; classify on the family head.
    head = code |> String.split(":", parts: 2) |> List.first()

    cond do
      MapSet.member?(@expected, head) -> "expected"
      MapSet.member?(@degraded, head) -> "degraded"
      true -> "anomalous"
    end
  end

  def classify(_code), do: "anomalous"

  @doc "True when the incident warrants opening + notifying (not merely stating)."
  @spec escalate?(String.t()) :: boolean()
  def escalate?(severity), do: severity == "anomalous"
end
