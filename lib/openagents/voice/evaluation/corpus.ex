defmodule OpenAgents.Voice.Evaluation.Corpus do
  @moduledoc "Loads the committed governed-voice contract regression corpus."

  alias OpenAgents.Provenance.Canonical

  @path "sarah/evals/voice/corpus.v1.json"
  @schema "sarah.voice.eval_corpus.v1"
  @required_risks ~w(
    identity_drift
    unsupported_memory_claim
    false_completion
    tool_bypass
    interrupted_authority
    transcript_correction
  )

  @spec load() :: {:ok, map()} | {:error, atom() | tuple()}
  def load do
    with {:ok, path} <- corpus_path(),
         {:ok, contents} <- File.read(path),
         {:ok, corpus} <- Jason.decode(contents),
         :ok <- validate(corpus) do
      {:ok, Map.put(corpus, "digest", Canonical.digest!(corpus))}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_corpus_json}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load!() :: map()
  def load! do
    case load() do
      {:ok, corpus} -> corpus
      {:error, reason} -> raise ArgumentError, "invalid voice corpus: #{inspect(reason)}"
    end
  end

  @spec validate(term()) :: :ok | {:error, atom() | tuple()}
  def validate(%{"schema" => @schema, "id" => id, "revision" => 1, "cases" => cases})
      when is_binary(id) and id != "" and is_list(cases) and length(cases) in 6..100 do
    with :ok <- validate_cases(cases),
         :ok <- validate_unique_ids(cases),
         :ok <- validate_risk_coverage(cases) do
      :ok
    end
  end

  def validate(_corpus), do: {:error, :invalid_corpus_shape}

  defp validate_cases(cases) do
    Enum.reduce_while(cases, :ok, fn regression_case, :ok ->
      case validate_case(regression_case) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_case(%{
         "id" => id,
         "risk" => risk,
         "description" => description,
         "trace" => trace,
         "expected_violations" => violations
       })
       when is_binary(id) and byte_size(id) in 1..80 and
              is_binary(description) and byte_size(description) in 1..500 and
              is_map(trace) and is_list(violations) and length(violations) <= 10 do
    cond do
      risk != "control" and risk not in @required_risks ->
        {:error, {:invalid_risk, id}}

      not Enum.all?(violations, &(&1 in @required_risks)) ->
        {:error, {:invalid_expected_violations, id}}

      length(violations) != length(Enum.uniq(violations)) ->
        {:error, {:duplicate_expected_violations, id}}

      true ->
        :ok
    end
  end

  defp validate_case(_case), do: {:error, :invalid_case}

  defp validate_unique_ids(cases) do
    ids = Enum.map(cases, & &1["id"])
    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_case_id}
  end

  defp validate_risk_coverage(cases) do
    covered = MapSet.new(cases, & &1["risk"])

    case Enum.find(@required_risks, &(not MapSet.member?(covered, &1))) do
      nil -> :ok
      risk -> {:error, {:missing_required_risk, risk}}
    end
  end

  defp corpus_path do
    case :code.priv_dir(:openagents) do
      path when is_list(path) -> {:ok, Path.join(List.to_string(path), @path)}
      {:error, reason} -> {:error, {:priv_dir_unavailable, reason}}
    end
  end
end
