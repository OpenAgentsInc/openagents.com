defmodule OpenAgents.Incidents.Fixer do
  @moduledoc """
  Spawns a durable fixer job for an anomalous incident — Sarah beginning to heal
  her own errors.

  A fixer is a `OpenAgents.Work.Job` whose goal is the incident: reproduce, diagnose
  in the repo, and **propose** a minimal patch (open a PR). It proposes, it does
  not deploy — the change rides the normal review path, and its delegation is
  gated by the same machine-pairing approval receipts every computer delegation
  is. The job runs on the owner's paired machine via the governed tools.

  Safe by default: autonomous fixing is **off** unless
  `config :openagents, :incident_fixer_enabled` is true. Until an operator enables
  it, anomalous incidents are still recorded and notified — they simply are not
  auto-worked. This is the audit's "earned one incident-class at a time, never
  switched on globally". Even when enabled, the fixer is de-duped (one open
  fixer per code per owner) and rate-limited per window.
  """

  alias OpenAgents.Incidents
  alias OpenAgents.Incidents.Incident
  alias OpenAgents.{Machines, Work}

  require Logger

  @maximum_fixers_per_window 3
  @window_seconds 3_600

  @spec maybe_spawn(Incident.t()) :: {:ok, :spawned | :skipped} | {:error, term()}
  def maybe_spawn(%Incident{} = incident) do
    cond do
      not enabled?() ->
        {:ok, :skipped}

      not spawnable?(incident) ->
        {:ok, :skipped}

      true ->
        spawn_fixer(incident)
    end
  rescue
    error ->
      Logger.error("incident_fixer_failed error=#{Exception.message(error)}")
      {:error, :incident_fixer_failed}
  end

  @doc "Whether autonomous fixing is switched on for this deployment."
  def enabled?, do: Application.get_env(:openagents, :incident_fixer_enabled, false) == true

  # Only user-facing turn/voice failures are auto-fixed. A failed background job
  # (origin job_server) is never fixed by spawning another background job, so a
  # failing fixer can never recurse into a new fixer.
  @fixable_origins ~w(turn_server voice_session)

  # A fixer needs a fixable origin, an owner, a conversation to report back into,
  # a paired machine to work on, no fixer already attached, and headroom under
  # the rate limit.
  defp spawnable?(%Incident{} = incident) do
    incident.origin in @fixable_origins and
      is_binary(incident.owner_visitor_id) and is_binary(incident.owner_user_id) and
      is_binary(incident.conversation_id) and is_nil(incident.fixer_job_id) and
      Machines.active_machine?(incident.owner_user_id) and
      under_rate_limit?(incident.owner_user_id)
  end

  defp under_rate_limit?(owner_user_id) do
    Incidents.active_fixer_count(owner_user_id, @window_seconds) < @maximum_fixers_per_window
  end

  defp spawn_fixer(%Incident{} = incident) do
    goal = fixer_goal(incident)

    attributes = %{
      conversation_id: incident.conversation_id,
      owner_visitor_id: incident.owner_visitor_id,
      surface: "text",
      goal: goal,
      context_hint: "incident:#{incident.code}",
      requesting_tool_step_ref: "incident:#{incident.id}"
    }

    case Work.start_job(attributes) do
      {:ok, job} ->
        {:ok, _updated} = Incidents.attach_fixer(incident, job.id)
        Logger.warning("incident_fixer_spawned incident=#{incident.id} job=#{job.id}")
        {:ok, :spawned}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A self-contained goal: it must run without this conversation's context, so it
  # states the incident and the guardrail (propose, do not deploy) inline.
  defp fixer_goal(%Incident{} = incident) do
    context = incident.context |> Jason.encode!() |> String.slice(0, 800)

    """
    A production incident was recorded in OpenAgents. Investigate and propose a fix.

    code: #{incident.code}
    origin: #{incident.origin}
    surface: #{incident.surface}
    summary: #{incident.summary}
    context: #{context}

    Delegate to a coding agent on the paired computer. Reproduce the failure in
    the OpenAgentsInc/sarah repo if you can, diagnose the root cause, and propose
    a MINIMAL patch by opening a pull request. Do NOT deploy and do NOT push to
    main directly — propose only. Report what you found and what you changed.
    """
    |> String.slice(0, 2_000)
  end
end
