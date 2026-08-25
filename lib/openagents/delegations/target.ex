defmodule OpenAgents.Delegations.Target do
  @moduledoc """
  One vocabulary for addressing a delegation target, reading its lifecycle, and
  advertising what the asking caller may do to it right now.

  Five surfaces want to hand work to a computer: the Work path, chat, text,
  voice, and the authenticated API. They differ in who is asking and how the
  answer is drawn. They share three questions, and this module is the only
  place that answers them.

  1. **How is it addressed?** By the kind-prefixed reference `OpenAgents.Delegations`
     already parses — `box:{uuid}` or `computer:{uuid}`. Nothing here mints a
     second identifier.
  2. **What is it doing?** `lifecycle/0` is one word drawn from the
     `openagents.cloud_computer.v1` state enum, computed from whichever
     substrate owns the target. The substrate's own state travels beside it
     untouched, because the substrate is still the authority and the unified
     word is a projection of it.
  3. **What may this caller do to it?** `capabilities` is an explicit list,
     computed once from the lifecycle and the authority the caller already
     proved. A surface renders that list. It never re-derives it.

  The third question is the one that earns the module. Reach is scoped per
  target kind (IDENTITY-009), so a surface that decides for itself whether a
  caller may start work on a target is a surface that can widen reach past the
  substrate. Computing it here makes the other four surfaces render-only.

  ## Custody is structural, never inferred

  `custody/1` answers whether a target is OpenAgents-managed or the customer's
  own premises, and it is derived from the target kind alone. It cannot be
  reached from the route that received the request, from whether the caller
  typed or spoke, or from anything else about the asking. A Box is provisioned
  and reclaimed by this application; a Computer is somebody's laptop. That is a
  property of the thing, not of the question.

  ## What is deliberately absent

  There is no runtime class for a Box. `OpenAgents.Capacity.Catalog` admits
  `standard`, `strong`, `batch`, and `connected`, and each names an isolation,
  an egress posture, and a data location. A paired computer is `connected` by
  construction and the capacity evidence already counts it as one. A Box is
  rented from a third party and nothing in this repository establishes its
  egress posture, so calling it `standard` would publish a containment claim
  no test backs. `runtime_class/1` returns `nil` for a Box until that evidence
  exists. See `docs/2026-08-25-delegation-target-seam.md`.
  """

  alias OpenAgents.Machines.Machine

  @lifecycles ~w(cold queued starting active stopping failed destroyed)
  @delegation_lifecycles ~w(queued starting active succeeded failed cancelled)
  @custodies ~w(openagents_managed customer_premises)
  @kinds ~w(box computer)

  @doc """
  The target lifecycle vocabulary.

  These are the seven states of `openagents.cloud_computer.v1` verbatim. The
  Elixir side maps onto the contract rather than inventing a parallel set, so
  a target described here keeps its word when a control plane starts producing
  one.
  """
  @spec lifecycles() :: [String.t()]
  def lifecycles, do: @lifecycles

  @doc "The delegation lifecycle vocabulary. A delegation ends; a target persists."
  @spec delegation_lifecycles() :: [String.t()]
  def delegation_lifecycles, do: @delegation_lifecycles

  @spec custodies() :: [String.t()]
  def custodies, do: @custodies

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Who holds the target, from the target kind alone.

  This never reads the caller, the surface, or the route.
  """
  @spec custody(String.t()) :: String.t()
  def custody("box"), do: "openagents_managed"
  def custody("computer"), do: "customer_premises"

  @doc """
  The `OpenAgents.Capacity.Catalog` class this kind of target belongs to, or
  `nil` when no admitted class describes it.
  """
  @spec runtime_class(String.t()) :: String.t() | nil
  def runtime_class("computer"), do: "connected"
  def runtime_class("box"), do: nil

  @doc """
  The unified lifecycle of a Box, from its last observed substrate state.

  A Box that is provisioned but not yet bootstrapped reads as `starting`
  rather than `active`. Refusing to advertise work on a half-ready Box costs a
  caller one poll; advertising it costs a failed command.

  Two producers feed this. A `conversation_boxes` row carries one of
  `OpenAgents.Box.ConversationBox.states/0`. A fan-out item that admission has
  not yet let through carries the synthetic `queued` that
  `OpenAgents.Box.Fleet` gives it — a logical Box that has cost nothing and
  called nothing. That item is the only thing in this application that reaches
  the contract's `queued` state today.
  """
  @spec box_lifecycle(String.t()) :: String.t()
  def box_lifecycle(state) when is_binary(state) do
    case state do
      "queued" -> "queued"
      "init" -> "starting"
      "provisioning" -> "starting"
      "cloning" -> "starting"
      "provisioned" -> "starting"
      "ready" -> "active"
      "idle" -> "active"
      "running" -> "active"
      "archiving" -> "stopping"
      "archived" -> "destroyed"
      "error" -> "failed"
      _unknown -> "failed"
    end
  end

  @doc """
  The unified lifecycle of a Computer.

  `online?` is a live reachability read, so it is passed in rather than taken.
  A revoked Computer is `destroyed` — the credential is gone and no pairing
  brings the same record back. An unreachable one is `cold`: the laptop is
  shut, and nothing this application can do opens it.
  """
  @spec computer_lifecycle(Machine.t(), boolean()) :: String.t()
  def computer_lifecycle(%Machine{} = machine, online?) when is_boolean(online?) do
    cond do
      machine.status == "revoked" or not is_nil(machine.revoked_at) -> "destroyed"
      machine.status == "active" and online? -> "active"
      true -> "cold"
    end
  end

  @doc "The unified lifecycle of one Box run."
  @spec run_lifecycle(String.t()) :: String.t()
  def run_lifecycle(state) when is_binary(state) do
    case state do
      "admitted" -> "queued"
      "dispatched" -> "starting"
      "running" -> "active"
      "completed" -> "succeeded"
      "cancelled" -> "cancelled"
      "failed" -> "failed"
      "timed_out" -> "failed"
      "lost" -> "failed"
      _unknown -> "failed"
    end
  end

  @doc """
  The unified lifecycle of one Computer delegation, from its `work_jobs` status.

  `interrupted` and `budget_exhausted` both read as `failed`. The distinction
  survives in the job's own status, which every projection carries beside this
  word; collapsing it here keeps one cross-kind vocabulary from growing a
  branch per substrate.
  """
  @spec job_lifecycle(String.t()) :: String.t()
  def job_lifecycle(status) when is_binary(status) do
    case status do
      "queued" -> "queued"
      "running" -> "active"
      "completed" -> "succeeded"
      "cancelled" -> "cancelled"
      "failed" -> "failed"
      "interrupted" -> "failed"
      "budget_exhausted" -> "failed"
      _unknown -> "failed"
    end
  end

  @doc """
  The seam fields for one target: custody, runtime class, lifecycle, the
  capabilities this caller may exercise, and why it may not.

  `authorized?` is the per-kind reach the caller already proved. It is required
  rather than assumed, so a surface that forgets to check cannot get a
  capability list by omission.

  `unavailable_reason` is the lifecycle itself when the target is not startable,
  and `not_authorized` when the lifecycle allows what the caller does not. It
  deliberately introduces no third vocabulary: the kind and the lifecycle
  together already separate a shut laptop from a reclaimed Box.
  """
  @spec seam(String.t(), String.t(), boolean()) :: map()
  def seam(kind, lifecycle, authorized?)
      when kind in @kinds and lifecycle in @lifecycles and is_boolean(authorized?) do
    startable? = lifecycle == "active" and authorized?

    %{
      "custody" => custody(kind),
      "runtime_class" => runtime_class(kind),
      "lifecycle" => lifecycle,
      "capabilities" => if(startable?, do: ["start"], else: []),
      "unavailable_reason" => unavailable_reason(lifecycle, authorized?)
    }
  end

  @doc """
  The seam fields for one delegation: its unified lifecycle and whether this
  caller can still cancel it.

  A caller that resolved the delegation at all has already passed the same
  per-kind reach check the target required, so cancellation turns only on
  whether the delegation is still running.
  """
  @spec delegation_seam(String.t()) :: map()
  def delegation_seam(lifecycle) when lifecycle in @delegation_lifecycles do
    %{
      "lifecycle" => lifecycle,
      "capabilities" => if(lifecycle in ~w(queued starting active), do: ["cancel"], else: [])
    }
  end

  defp unavailable_reason("active", true), do: nil
  defp unavailable_reason("active", false), do: "not_authorized"
  defp unavailable_reason(lifecycle, _authorized?), do: lifecycle
end
