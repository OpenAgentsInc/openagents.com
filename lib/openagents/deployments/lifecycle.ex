defmodule OpenAgents.Deployments.Lifecycle do
  @moduledoc """
  The one place that says which deployment state may follow which.

  Every transition in the control plane is checked here before it is written, so
  a new caller, a retried worker, or a late provider callback cannot invent a
  path such as `waiting_for_approval -> succeeded`. Terminal states have no
  successors: a run that has finished stays finished, and a further attempt is a
  new run.
  """

  @transitions %{
    "requested" => ~w(checking waiting_for_approval queued failed cancelled superseded),
    "checking" => ~w(waiting_for_approval queued failed cancelled superseded),
    "waiting_for_approval" => ~w(queued failed cancelled superseded),
    "queued" => ~w(deploying failed cancelled superseded),
    "deploying" => ~w(succeeded failed cancelled),
    "succeeded" => [],
    "failed" => [],
    "cancelled" => [],
    "superseded" => []
  }

  @doc "The states that may legally follow `state`."
  @spec successors(String.t()) :: [String.t()]
  def successors(state) when is_binary(state), do: Map.get(@transitions, state, [])

  @doc "Whether `to` may legally follow `from`."
  @spec allowed?(String.t(), String.t()) :: boolean()
  def allowed?(from, to) when is_binary(from) and is_binary(to), do: to in successors(from)

  @doc """
  Check one transition, returning a typed error rather than a boolean.

  The error names both states so a rejected transition is legible in an event
  detail without the caller reconstructing it.
  """
  @spec check(String.t(), String.t()) ::
          :ok | {:error, {:illegal_transition, String.t(), String.t()}}
  def check(from, to) when is_binary(from) and is_binary(to) do
    if allowed?(from, to), do: :ok, else: {:error, {:illegal_transition, from, to}}
  end

  @doc "The full transition table, for documentation and proofs."
  @spec transitions() :: %{String.t() => [String.t()]}
  def transitions, do: @transitions
end
