defmodule OpenAgents.Cluster.Admission do
  @moduledoc """
  Controls whether the local node can enter external readiness.

  A rolling provider removes admission before it drains or replaces a node.
  The state is node-local and content-free. A fresh VM starts admitted, but the
  endpoint remains unavailable until boot convergence and database checks pass.
  """

  @state_key {__MODULE__, :ready}

  @doc "Remove the local node from readiness."
  def remove do
    :persistent_term.put(@state_key, false)
    :ok
  end

  @doc "Allow the local node to become ready after every other check passes."
  def restore do
    :persistent_term.put(@state_key, true)
    :ok
  end

  @doc "Return whether the local node is admitted to readiness."
  def ready?, do: :persistent_term.get(@state_key, true)
end
