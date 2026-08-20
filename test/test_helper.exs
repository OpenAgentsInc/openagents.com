# The :cluster tag spins up real distributed peer nodes (needs epmd) and leaves
# node-global distribution state behind, so those tests cannot share a BEAM with
# the rest of the suite — a module that expects an undistributed node sees
# net_kernel already running. Upstream runs them as their own gate stage
# (`mix test --only cluster`); this excludes them here for the same reason.
# Note the exclusion is unconditional: `--include skip` must not drag them back
# in, so a :cluster module carries the :cluster tag only, never :skip too.
ExUnit.start(exclude: [:skip, :cluster])

# The cluster stage needs the Erlang port mapper up before its first peer node.
# Leaving that to whichever module happened to run first made the stage
# order-dependent: modules scheduled ahead of it flunked "distribution
# unavailable". Idempotent, and only paid for when that stage is selected.
cluster_stage? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(&(&1 == :cluster or match?({:cluster, _}, &1)))

if cluster_stage? do
  try do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
  rescue
    # No epmd on PATH: the cluster tests flunk with their own clear message.
    _ -> :ok
  end
end

Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, :manual)
