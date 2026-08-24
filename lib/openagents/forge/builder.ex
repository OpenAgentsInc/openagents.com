defmodule OpenAgents.Forge.Builder do
  @moduledoc """
  Serial coordinator for durable, isolated forge build attempts.

  The coordinator creates a UUID receipt before queueing work, requires a
  verified digest-addressed artifact in durable storage before marking the
  target built, and periodically recovers stale `building` targets. Recovery
  expires the abandoned build ID and creates a different ID, so late sidecar
  responses cannot satisfy the retry.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildExecutor
  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.BuildReceipt
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Target
  alias OpenAgents.Forge.Targets
  alias OpenAgents.Repo

  @recovery_interval_ms 60_000
  @abandoned_after_ms 360_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :subscribe}}

  @impl true
  def handle_continue(:subscribe, state) do
    try do
      Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:target")
    rescue
      _error -> Process.send_after(self(), :resubscribe, 1_000)
    end

    send(self(), :recover_abandoned)
    {:noreply, state}
  end

  @impl true
  def handle_info(:resubscribe, state), do: handle_continue(:subscribe, state)

  def handle_info(:recover_abandoned, state) do
    recover_abandoned()
    Process.send_after(self(), :recover_abandoned, @recovery_interval_ms)
    {:noreply, state}
  end

  def handle_info({:forge_target, %{target_id: target_id}}, state) do
    run_promoted(target_id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_promoted(target_id) do
    case Targets.advance(target_id, "building") do
      {:ok, target} ->
        run_attempt(target)

      {:error, reason} ->
        Logger.debug("forge_build_not_owner code=#{OpenAgents.OperationalLog.code(reason)}")
        :ok
    end
  rescue
    error ->
      fail_target(
        target_id,
        "builder_crashed",
        "code=" <> OpenAgents.OperationalLog.code(error)
      )
  catch
    _kind, reason ->
      fail_target(
        target_id,
        "builder_crashed",
        "code=" <> OpenAgents.OperationalLog.code(reason)
      )
  end

  defp run_attempt(%Target{} = target) do
    build_id = Ecto.UUID.generate()
    baseline_manifest = live_manifest(target.repo)

    receipt =
      %BuildReceipt{id: build_id}
      |> BuildReceipt.start_changeset(%{
        repo: target.repo,
        sha: target.sha,
        target_id: target.id,
        baseline_manifest: baseline_manifest
      })
      |> Repo.insert()

    case receipt do
      {:ok, receipt} ->
        opts = [
          build_id: build_id,
          target_id: target.id,
          baseline_manifest: baseline_manifest
        ]

        case executor().build(target.repo, target.sha, opts) do
          {:ok, result} -> finish(target, receipt, result)
          {:error, error} -> fail_attempt(target, receipt, error)
        end

      {:error, changeset} ->
        Logger.debug(
          "forge_build_attempt_not_owner code=#{OpenAgents.OperationalLog.code(changeset)}"
        )
    end
  rescue
    error ->
      if receipt = running_receipt(target.id) do
        fail_attempt(target, receipt, %{
          code: "builder_crashed",
          output: "code=" <> OpenAgents.OperationalLog.code(error)
        })
      else
        fail_target(
          target.id,
          "builder_crashed",
          "code=" <> OpenAgents.OperationalLog.code(error)
        )
      end
  catch
    _kind, reason ->
      message = "code=" <> OpenAgents.OperationalLog.code(reason)

      if receipt = running_receipt(target.id) do
        fail_attempt(target, receipt, %{code: "builder_crashed", output: message})
      else
        fail_target(target.id, "builder_crashed", message)
      end
  end

  defp finish(target, receipt, result) do
    with {:ok, verified} <-
           BuildArtifact.verify(result.artifact_bytes,
             digest: result.artifact_digest,
             repo: target.repo,
             source_sha: target.sha,
             build_id: receipt.id
           ),
         true <- verified.manifest == result.manifest or {:error, :executor_manifest_mismatch},
         {:ok, artifact_abs, artifact_rel} <- store_local(result.artifact_bytes, verified.digest),
         {:ok, _key} <-
           OpenAgents.Forge.WAL.put_artifact(
             target.repo,
             verified.digest,
             result.artifact_bytes
           ),
         {:ok, _receipt} <- complete_receipt(receipt, artifact_rel, verified, result),
         {:ok, _target} <-
           Targets.advance(target.id, "built", %{
             "artifact" => artifact_rel,
             "artifact_digest" => verified.digest,
             "build_id" => receipt.id,
             "classification" => verified.manifest["classification"],
             "manifest" => verified.manifest,
             "modules" => verified.modules
           }) do
      Phoenix.PubSub.broadcast(
        OpenAgents.PubSub,
        "forge:builds",
        {:forge_build_ready,
         %{
           repo: target.repo,
           sha: target.sha,
           target_id: target.id,
           build_id: receipt.id,
           artifact: artifact_abs,
           artifact_digest: verified.digest,
           manifest: verified.manifest,
           modules: verified.modules
         }}
      )
    else
      {:error, reason} ->
        fail_attempt(target, receipt, %{
          code: "build_finalize_failed",
          output: inspect(reason)
        })

      false ->
        fail_attempt(target, receipt, %{
          code: "build_finalize_failed",
          output: "executor manifest mismatch"
        })
    end
  end

  defp complete_receipt(receipt, artifact_rel, verified, result) do
    Repo.transaction(fn ->
      current = Repo.get!(BuildReceipt, receipt.id, lock: "FOR UPDATE")

      if current.status != "running" do
        Repo.rollback(:attempt_not_running)
      end

      current
      |> BuildReceipt.complete_changeset(%{
        manifest: verified.manifest,
        modules: verified.modules,
        warnings: BuildExecutor.bound_output(result.warnings || ""),
        tests: result.tests,
        duration_ms: result.duration_ms,
        artifact: artifact_rel,
        artifact_digest: verified.digest,
        output_digest: result.output_digest,
        output_ref: result.output_ref
      })
      |> Repo.update!()
    end)
    |> case do
      {:ok, receipt} ->
        _ = OpenAgents.Issues.Evidence.record_build(receipt)
        {:ok, receipt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fail_attempt(target, receipt, error) do
    error = normalize_error(error)

    Repo.transaction(fn ->
      current = Repo.get(BuildReceipt, receipt.id, lock: "FOR UPDATE")

      if current && current.status == "running" do
        current
        |> BuildReceipt.terminal_changeset("failed", %{
          warnings: BuildExecutor.bound_output(error.output),
          duration_ms: Map.get(error, :duration_ms, 0),
          output_digest: Map.get(error, :output_digest),
          output_ref: Map.get(error, :output_ref),
          error_code: error.code
        })
        |> Repo.update!()
      end
    end)
    |> case do
      # A failed build is evidence too. An issue's history is what happened,
      # not what worked, so the edge is written for a failure exactly as it is
      # for a success.
      {:ok, %BuildReceipt{} = failed} -> OpenAgents.Issues.Evidence.record_build(failed)
      _not_running -> []
    end

    fail_target(target.id, error.code, error.output)
  end

  defp fail_target(target_id, code, output) do
    message = BuildExecutor.bound_output("#{code}: #{output}")

    case Targets.advance(target_id, "failed", %{"error" => message, "error_code" => code}) do
      {:ok, _target} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "forge_build_advance_failed status=failed code=#{OpenAgents.OperationalLog.code(reason)}"
        )
    end
  end

  defp normalize_error(%{code: code, output: output} = error) do
    %{
      code: safe_error_code(code),
      output: to_string(output),
      duration_ms: Map.get(error, :duration_ms, 0),
      output_digest: Map.get(error, :output_digest),
      output_ref: Map.get(error, :output_ref)
    }
  end

  defp normalize_error(output) do
    %{code: "build_failed", output: to_string(output), duration_ms: 0}
  end

  defp safe_error_code(code) do
    code
    |> to_string()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.slice(0, 128)
    |> case do
      "" -> "build_failed"
      value -> value
    end
  end

  defp store_local(bytes, digest) do
    artifact_rel = Path.join("beams", digest <> ".tar")
    artifact_abs = Path.join(Repos.data_dir(), artifact_rel)

    case BuildProtocol.atomic_write(artifact_abs, bytes) do
      :ok ->
        {:ok, artifact_abs, artifact_rel}

      {:error, :destination_exists} ->
        with {:ok, existing} <- File.read(artifact_abs),
             true <- BuildArtifact.digest(existing) == digest or {:error, :digest_collision} do
          {:ok, artifact_abs, artifact_rel}
        end

      {:error, reason} ->
        {:error, {:artifact_cache_write_failed, reason}}
    end
  end

  defp live_manifest(repo) do
    case Targets.live(repo) do
      nil ->
        nil

      %Target{id: target_id} ->
        BuildReceipt
        |> where([b], b.target_id == ^target_id and b.status == "complete")
        |> where([b], not is_nil(b.manifest))
        |> order_by([b], desc: b.inserted_at)
        |> select([b], b.manifest)
        |> limit(1)
        |> Repo.one()
    end
  end

  defp recover_abandoned do
    Target
    |> where([t], t.status == "building")
    |> Repo.all()
    |> Enum.each(&recover_target/1)
  rescue
    error ->
      Logger.warning("forge_build_recovery_failed code=#{OpenAgents.OperationalLog.code(error)}")
  end

  defp recover_target(target) do
    :global.trans({{:forge_build_recovery, target.id}, self()}, fn ->
      case running_receipt(target.id) do
        nil ->
          run_attempt(target)

        receipt ->
          if abandoned?(receipt) do
            receipt
            |> BuildReceipt.terminal_changeset("expired", %{
              error_code: "builder_restart_expired",
              warnings: "build coordinator disappeared before completion",
              duration_ms: 0
            })
            |> Repo.update!()

            run_attempt(target)
          end
      end
    end)
  end

  defp running_receipt(target_id) do
    BuildReceipt
    |> where([b], b.target_id == ^target_id and b.status == "running")
    |> order_by([b], desc: b.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp abandoned?(receipt) do
    threshold =
      Application.get_env(:openagents, :forge_build_abandoned_after_ms, @abandoned_after_ms)

    DateTime.diff(DateTime.utc_now(), receipt.updated_at || receipt.inserted_at, :millisecond) >=
      threshold
  end

  defp executor do
    Application.get_env(
      :openagents,
      :forge_build_executor,
      OpenAgents.Forge.BuildExecutor.Sidecar
    )
  end
end
