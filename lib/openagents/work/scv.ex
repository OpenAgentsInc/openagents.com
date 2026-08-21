defmodule OpenAgents.Work.Scv do
  @moduledoc """
  The `scv` job kind's lifecycle edges (SCV-001): the bounds an SCV run is
  admitted under, the runtime options handed to the OpenCode driver, the
  disposable workspace's terminal cleanup, and metering the run's token usage
  into the same grant ledger as every other kind (`inference_grants`).

  The job itself is an ordinary `work_jobs` row driven by
  `OpenAgents.Work.ScvServer`, exactly as a computer delegation is driven by
  `OpenAgents.Work.DelegationServer`. This module only answers the
  kind-specific questions that loop asks, the way `OpenAgents.Work.Coding`
  does for the coding kind.
  """

  require Logger

  alias OpenAgents.Inference
  alias OpenAgents.Repo
  alias OpenAgents.SCV.Workspace
  alias OpenAgents.Work.Job

  @kind "scv"

  # An objective is a prompt, not a corpus. The bound is the same one a
  # delegated goal carries, so an SCV cannot smuggle in a larger instruction
  # than any other job kind.
  @maximum_objective_bytes 2_000

  @doc "Whether a job row is an SCV deployment."
  def scv?(%Job{kind: @kind}), do: true
  def scv?(_job), do: false

  @doc "The job kind string."
  def kind, do: @kind

  @doc "The largest admitted objective, in bytes."
  def maximum_objective_bytes, do: @maximum_objective_bytes

  @doc "The configured SCV deployment settings."
  def settings, do: Application.fetch_env!(:openagents, :scv_deploy)

  @doc "Whether the SCV deployment lane is admitted in this runtime."
  def enabled?, do: Keyword.fetch!(settings(), :enabled) == true

  @doc "The admitted OpenCode model slug, `provider/model`."
  def model, do: Keyword.fetch!(settings(), :model)

  @doc "How many SCV deployments may run at once across the whole application."
  def concurrency_limit, do: Keyword.fetch!(settings(), :concurrency_limit)

  @doc "The wall clock one SCV deployment is admitted for, in milliseconds."
  def wall_clock_ms, do: Keyword.fetch!(settings(), :wall_clock_ms)

  @doc "The largest process output one SCV deployment may capture, in bytes."
  def maximum_output_bytes, do: Keyword.fetch!(settings(), :maximum_output_bytes)

  @doc """
  The bounded execution budget recorded on the job row at admission.

  The job reads its wall clock from this immutable snapshot rather than from
  configuration, so a configuration change mid-run cannot widen a run that was
  already admitted.
  """
  def budget_snapshot do
    %{
      "wall_clock_ms" => wall_clock_ms(),
      "maximum_objective_bytes" => @maximum_objective_bytes,
      "maximum_output_bytes" => maximum_output_bytes(),
      "maximum_report_bytes" => Job.maximum_report_bytes()
    }
  end

  @doc "The runtime authority recorded on the job row at admission."
  def authority_snapshot(%{owner: owner, repository: repository, revision: revision}) do
    %{
      "driver" => "opencode",
      "environment" => "opencode-core",
      "permission_profile" => "read_only",
      "model" => model(),
      "repository_id" => repository.id,
      "repository_path" => "#{repository.owner}/#{repository.name}",
      "repository_revision" => revision,
      "operator_user_id" => owner.id
    }
  end

  @doc "The wall clock this job was admitted under."
  def wall_clock_ms(%Job{budget_snapshot: %{"wall_clock_ms" => value}})
      when is_integer(value) and value > 0,
      do: value

  def wall_clock_ms(%Job{}), do: wall_clock_ms()

  @doc "The output ceiling this job was admitted under."
  def maximum_output_bytes(%Job{budget_snapshot: %{"maximum_output_bytes" => value}})
      when is_integer(value) and value > 0,
      do: value

  def maximum_output_bytes(%Job{}), do: maximum_output_bytes()

  @doc """
  The driver options for one admitted run.

  `models_fetch` is deliberately on: the admitted model is served by a gateway
  whose catalog is published rather than baked into the OpenCode binary, so a
  run with the catalog fetch disabled would resolve no model at all. Tool
  permissions stay denied either way — this widens what the process may read
  about models, not what it may do.
  """
  def driver_options(%Job{} = job, event_sink) when is_function(event_sink, 1) do
    configured = settings()

    [
      model: model(),
      reasoning_effort: Keyword.fetch!(configured, :reasoning_effort),
      models_fetch: true,
      api_key: Application.get_env(:openagents, :openai_api_key),
      opencode_api_key: Keyword.get(configured, :opencode_api_key),
      output_root: Keyword.fetch!(configured, :output_root),
      timeout_ms: wall_clock_ms(job),
      maximum_output_bytes: maximum_output_bytes(job),
      event_sink: event_sink
    ]
    |> maybe_put(:executable, Keyword.get(configured, :executable))
  end

  @doc """
  Mint the run's inference grant at start; its id rides in the job's
  `delegation` map. The token is discarded — the meter is internal, and
  nothing external redeems it.
  """
  def on_start(%Job{kind: @kind} = job) do
    case Inference.mint(%{
           owner_visitor_id: job.owner_visitor_id,
           conversation_id: job.conversation_id,
           machine_id: nil
         }) do
      {:ok, grant, _token} ->
        job
        |> Ecto.Changeset.change(%{
          delegation: Map.put(job.delegation || %{}, "inference_grant_id", grant.id)
        })
        |> Repo.update()

      {:error, reason} ->
        Logger.warning("scv_job_grant_mint_failed code=#{OpenAgents.OperationalLog.code(reason)}")

        {:ok, job}
    end
  end

  def on_start(job), do: {:ok, job}

  @doc """
  Terminal filesystem cleanup, called from `Work.finish_job/3` post-commit —
  the one path that runs even when the worker died, so a workspace outlives
  neither the run nor the node that held it.
  """
  def on_terminal(%Job{kind: @kind} = job) do
    case job.delegation do
      %{"workspace_path" => path} when is_binary(path) -> Workspace.destroy(path)
      _absent -> :ok
    end

    :ok
  end

  def on_terminal(_job), do: :ok

  @doc "Settle an SCV run's metered grant inside the terminal job transaction."
  def settle_grant(%Job{kind: @kind, delegation: %{"inference_grant_id" => grant_id}} = job)
      when is_binary(grant_id) do
    case Repo.get(Inference.Grant, grant_id) do
      nil ->
        {:error, :scv_grant_missing}

      grant ->
        usage = job.usage || %{}

        with {:ok, metered} <-
               Inference.record_usage(grant, %{
                 "input_tokens" => Map.get(usage, "input_tokens", 0),
                 "output_tokens" => Map.get(usage, "output_tokens", 0),
                 "total_tokens" => Map.get(usage, "total_tokens", 0)
               }),
             {:ok, settled} <- Inference.revoke(metered) do
          {:ok, settled}
        end
    end
  end

  def settle_grant(%Job{kind: @kind}), do: {:ok, :no_grant}
  def settle_grant(_job), do: {:ok, :not_scv}

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)
end
