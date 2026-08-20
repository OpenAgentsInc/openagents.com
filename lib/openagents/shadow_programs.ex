defmodule OpenAgents.ShadowPrograms do
  @moduledoc "Runs and persists typed shadow comparisons with zero live effect."

  import Ecto.Query

  alias OpenAgents.ProgramArtifacts.Snapshot
  alias OpenAgents.ProgramArtifacts.Reader
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo
  alias OpenAgents.ShadowPrograms.{Run, Schema, Signatures}

  @spec run(Ecto.UUID.t(), String.t(), map(), Snapshot.t(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def run(turn_receipt_id, signature_id, input, snapshot, options \\ []) do
    provider = Keyword.get(options, :provider, configured_provider())
    timeout_ms = Keyword.get(options, :timeout_ms, configured_timeout())
    started = System.monotonic_time(:millisecond)

    with {:ok, signature} <- Signatures.fetch(signature_id),
         :ok <- validate_snapshot(snapshot, signature_id),
         :ok <- Schema.validate(input, signature.input_schema) do
      result = evaluate(provider, snapshot, signature, input, timeout_ms)
      latency_ms = max(System.monotonic_time(:millisecond) - started, 0)
      persist(turn_receipt_id, signature, input, snapshot, provider, result, latency_ms)
    end
  end

  @spec maybe_start(Ecto.UUID.t(), String.t(), Snapshot.t()) ::
          :disabled | {:ok, pid()} | {:error, term()}
  def maybe_start(turn_receipt_id, current_user_text, snapshot)
      when is_binary(current_user_text) do
    config = Application.fetch_env!(:openagents, :shadow_programs)

    if Keyword.fetch!(config, :enabled) do
      Task.Supervisor.start_child(OpenAgents.ShadowProgramTaskSupervisor, fn ->
        _result =
          run(
            turn_receipt_id,
            "sarah.memory.intent.v1",
            %{"current_user_text" => current_user_text},
            snapshot
          )

        :ok
      end)
    else
      :disabled
    end
  end

  @doc "Returns bounded aggregate quality/latency/token evidence without private inputs or outputs."
  def report(signature_id) when is_binary(signature_id) do
    runs =
      from(run in Run,
        where: run.signature_id == ^signature_id,
        order_by: [desc: run.inserted_at],
        limit: 10_000,
        select: %{
          status: run.status,
          comparison: run.comparison,
          usage: run.usage,
          latency_ms: run.latency_ms
        }
      )
      |> Repo.all()

    completed = Enum.count(runs, &(&1.status == "completed"))
    exact = Enum.count(runs, & &1.comparison["exact_match"])

    %{
      "schema" => "sarah.shadow_report.v1",
      "signature_id" => signature_id,
      "runs" => length(runs),
      "completed" => completed,
      "degraded_or_failed" => length(runs) - completed,
      "baseline_candidate_exact_rate" => ratio(exact, length(runs)),
      "average_latency_ms" => average(Enum.map(runs, & &1.latency_ms)),
      "input_tokens" => sum_usage(runs, "input_tokens"),
      "output_tokens" => sum_usage(runs, "output_tokens"),
      "private_content_included" => false
    }
  end

  defp evaluate(_provider, %Snapshot{artifact: nil}, signature, _input, _timeout_ms),
    do: {:degraded, signature.baseline, :no_admitted_artifact, nil}

  defp evaluate(provider, %Snapshot{artifact: artifact}, signature, input, timeout_ms) do
    if artifact.signature_id != signature.id do
      {:degraded, signature.baseline, :artifact_signature_mismatch, nil}
    else
      case provider.evaluate(artifact, signature, input, timeout_ms) do
        {:ok, response} -> validate_candidate(response, signature, input)
        {:error, :timed_out} -> {:timed_out, signature.baseline, :timed_out, nil}
        {:error, reason} -> {:failed, signature.baseline, bounded_code(reason), nil}
      end
    end
  end

  defp validate_candidate(response, signature, input) do
    with :ok <- validate_candidate_output(signature.id, response.output, input) do
      {:completed, response.output, nil, response}
    else
      {:error, reason} -> {:malformed, signature.baseline, bounded_code(reason), response}
    end
  end

  @doc false
  def validate_candidate_output(signature_id, output, input) do
    with {:ok, signature} <- Signatures.fetch(signature_id),
         :ok <- Schema.validate(output, signature.output_schema),
         :ok <- validate_semantics(signature.id, output, input) do
      :ok
    end
  end

  defp persist(
         turn_receipt_id,
         signature,
         input,
         snapshot,
         provider,
         {status, candidate, failure_code, response},
         latency_ms
       ) do
    attributes = %{
      signature_id: signature.id,
      signature_version: signature.version,
      artifact_id: artifact_value(snapshot, :id),
      artifact_digest: artifact_value(snapshot, :digest),
      input_digest: Canonical.digest!(input),
      baseline_output: signature.baseline,
      candidate_output: safe_output(candidate),
      candidate_output_digest: Canonical.digest!(candidate),
      status: Atom.to_string(status),
      comparison: comparison(signature.baseline, candidate),
      provider_id: provider_id(provider),
      provider_response_id: response && response.response_id,
      usage: if(response, do: response.usage, else: %{}),
      latency_ms: latency_ms,
      failure_code: failure_code && to_string(failure_code),
      completed_at: DateTime.utc_now()
    }

    %Run{turn_receipt_id: turn_receipt_id}
    |> Run.changeset(attributes)
    |> Repo.insert()
  end

  defp comparison(baseline, candidate) do
    %{
      "schema" => "sarah.shadow_comparison.v1",
      "exact_match" => baseline == candidate,
      "baseline_digest" => Canonical.digest!(baseline),
      "candidate_digest" => Canonical.digest!(candidate)
    }
  end

  defp validate_semantics("sarah.capability.route.v1", output, input) do
    selected = output["selected_capability_id"]
    available = input["captured_capability_ids"] || []

    if is_nil(selected) or selected in available,
      do: :ok,
      else: {:error, :uncaptured_capability_selected}
  end

  defp validate_semantics(_signature_id, _output, _response), do: :ok

  defp safe_output(output) do
    %{
      "withheld" => true,
      "keys" => output |> Map.keys() |> Enum.sort()
    }
  end

  defp artifact_value(%Snapshot{artifact: nil}, _field), do: nil
  defp artifact_value(%Snapshot{artifact: artifact}, field), do: Map.fetch!(artifact, field)

  defp provider_id(provider) do
    if function_exported?(provider, :id, 0), do: provider.id(), else: inspect(provider)
  end

  defp bounded_code(reason) when is_atom(reason), do: reason
  defp bounded_code({kind, _detail}) when is_atom(kind), do: kind
  defp bounded_code(_reason), do: :shadow_failed

  defp validate_snapshot(%Snapshot{artifact: nil} = snapshot, signature_id) do
    if snapshot.signature_id == signature_id and snapshot.degraded? and
         snapshot.receipt["signature_id"] == signature_id and
         snapshot.receipt["artifact_id"] == nil,
       do: :ok,
       else: {:error, :invalid_shadow_artifact_snapshot}
  end

  defp validate_snapshot(%Snapshot{artifact: artifact} = snapshot, signature_id) do
    if snapshot.signature_id == signature_id and not snapshot.degraded? and
         artifact.signature_id == signature_id and
         Reader.digest(artifact.document) == artifact.digest and
         snapshot.receipt["artifact_id"] == artifact.id and
         snapshot.receipt["artifact_digest"] == artifact.digest,
       do: :ok,
       else: {:error, :invalid_shadow_artifact_snapshot}
  end

  defp validate_snapshot(_snapshot, _signature_id),
    do: {:error, :invalid_shadow_artifact_snapshot}

  defp configured_provider do
    Application.fetch_env!(:openagents, :shadow_programs) |> Keyword.fetch!(:provider)
  end

  defp configured_timeout do
    Application.fetch_env!(:openagents, :shadow_programs) |> Keyword.fetch!(:timeout_ms)
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator
  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp sum_usage(runs, key) do
    Enum.reduce(runs, 0, fn run, total ->
      case run.usage[key] do
        value when is_integer(value) and value >= 0 -> total + value
        _missing -> total
      end
    end)
  end
end
