defmodule OpenAgents.Deployments.Worker do
  @moduledoc """
  Drives queued deployment runs to a terminal state.

  The worker owns no state that matters. Everything it needs is in the database:
  the run, its lease, its attempt count, and its policy explanation. Restarting
  the worker, or losing the machine it runs on, therefore loses no deployment —
  `OpenAgents.Deployments.reconcile_leases/2` reclaims what the old worker held.

  One pass does, for one run:

    1. Claim a queued run by taking a lease. The claim is a conditional update,
      so two workers cannot claim the same run.
    2. Re-check the authority behind the request and re-evaluate policy. A run
      queued an hour ago is not admitted now if the environment froze or the
      requester lost membership.
    3. Resolve secrets and hand the provider an immutable execution.
    4. Record the provider's result, treating an uncertain result as an
      explicitly uncertain failure rather than a success.

  A cancellation requested while the provider is running is observed here, after
  the provider returns, so the run reaches a terminal state through the lifecycle
  rather than by the canceller's assertion.
  """

  use GenServer

  require Logger

  alias OpenAgents.Deployments
  alias OpenAgents.Deployments.Principal
  alias OpenAgents.Deployments.Provider
  alias OpenAgents.Deployments.Run

  @default_interval 1_000

  @doc "Start the worker loop."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc """
  Run one pass synchronously, returning what it did.

  Tests and operators drive the loop through this call, so no test has to sleep
  and no operator has to guess whether a tick happened.
  """
  @spec tick(GenServer.server()) :: {:ok, Run.t()} | :empty | {:error, term()}
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 30_000)

  @impl GenServer
  def init(options) do
    state = %{
      identity: Keyword.get_lazy(options, :identity, &default_identity/0),
      interval: Keyword.get(options, :interval, @default_interval),
      lease_seconds: Keyword.get(options, :lease_seconds, 300),
      poll: Keyword.get(options, :poll, true)
    }

    if state.poll, do: schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:tick, _from, state), do: {:reply, run_once(state), state}

  @impl GenServer
  def handle_info(:tick, state) do
    _result = run_once(state)
    schedule(state)
    {:noreply, state}
  end

  @doc """
  Execute one claimed run to a terminal state.

  Exposed so a recovery path or a test can drive one exact run without racing the
  claim query.
  """
  @spec execute(Run.t(), String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def execute(%Run{} = run, identity, options \\ []) do
    principal = Principal.system(identity)

    with {:ok, {repository, environment, request}} <- Deployments.load_run_context(run),
         :ok <- Deployments.recheck_request_authority(repository, environment, request),
         {:ok, %Run{state: "queued"} = run} <-
           Deployments.reevaluate(repository, environment, request, run, principal),
         {:ok, run} <- Deployments.transition(run, "deploying", principal),
         {:ok, module} <- Provider.fetch(environment.provider),
         {:ok, execution} <-
           Deployments.build_execution(repository, environment, request, run, options) do
      result = deploy(module, execution)
      secret_values = Map.values(execution.secrets)

      finish(run, identity, result, secret_values)
    else
      {:ok, %Run{} = run} ->
        # Policy moved the run somewhere other than `queued`; that decision and
        # its explanation are already durable.
        {:ok, run}

      {:error, reason} ->
        halt(run, identity, reason)
    end
  end

  defp run_once(state) do
    case Deployments.claim_run(state.identity, lease_seconds: state.lease_seconds) do
      {:ok, run} -> execute(run, state.identity, timeout_seconds: state.lease_seconds)
      :empty -> :empty
    end
  end

  # A provider that raises or exits is uncertain, not failed: an exception after
  # the API call was made says nothing about whether the deployment happened.
  defp deploy(module, execution) do
    module.deploy(execution)
  rescue
    exception ->
      # Only the exception's type is logged. Its message can carry provider
      # response bodies, which can carry a resolved secret.
      Logger.error("deployment_provider_raised code=#{inspect(exception.__struct__)}")
      {:uncertain, %{"detail" => "provider raised"}}
  catch
    :exit, _reason -> {:uncertain, %{"detail" => "provider exited"}}
  end

  defp finish(%Run{} = run, identity, result, secret_values) do
    Deployments.finish_run(reloaded(run), identity, result, secret_values: secret_values)
  end

  # The run is reloaded before the terminal write so a cancellation requested
  # while the provider was running is visible to the transition.
  defp reloaded(%Run{} = run) do
    case OpenAgents.Repo.get(Run, run.id) do
      %Run{} = reloaded -> reloaded
      nil -> run
    end
  end

  # Reloaded because a halt can happen after the run already moved to
  # `deploying`, and the transition is conditional on the state it reads.
  defp halt(%Run{} = run, identity, reason) do
    principal = Principal.system(identity)

    case Deployments.transition(reloaded(run), "failed", principal,
           reason: failure_reason(reason),
           event_type: "worker_halted"
         ) do
      {:ok, halted} -> {:ok, halted}
      {:error, _transition_error} -> {:error, reason}
    end
  end

  defp failure_reason({:forbidden, reason}), do: "authority_revoked_" <> Atom.to_string(reason)
  defp failure_reason({:missing_secret_reference, _reference}), do: "secret_unavailable"
  defp failure_reason({:undeclared_secret_reference, _reference}), do: "secret_undeclared"
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_reason), do: "worker_error"

  defp schedule(state), do: Process.send_after(self(), :tick, state.interval)

  defp default_identity do
    node = node() |> Atom.to_string() |> String.slice(0, 80)
    node <> ":" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  end
end
