defmodule OpenAgents.Persona.Evaluation.Runner do
  @moduledoc "Runs the committed corpus against an explicitly selected provider and model."

  alias OpenAgents.Context.Composer
  alias OpenAgents.Persona
  alias OpenAgents.Persona.Evaluation.{Corpus, Report, Scorer}
  alias OpenAgents.Providers.Request
  alias OpenAgents.Provenance.Canonical

  @maximum_response_bytes 65_536

  @spec run(module(), String.t()) :: {:ok, map()} | {:error, term()}
  def run(provider, model_id) when is_atom(provider) and is_binary(model_id) and model_id != "" do
    corpus = Corpus.load!()
    persona = Persona.current!()
    context = Composer.compose!()

    with {:ok, results} <- run_cases(corpus["cases"], provider, model_id, context.instructions) do
      {:ok, Report.build(corpus, persona, model_id, results)}
    end
  end

  defp run_cases(cases, provider, model_id, instructions) do
    Enum.reduce_while(cases, {:ok, []}, fn regression_case, {:ok, results} ->
      case run_case(regression_case, provider, model_id, instructions) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, {regression_case["id"], reason}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp run_case(regression_case, provider, model_id, instructions) do
    request = %Request{
      model_id: model_id,
      instructions: instructions,
      input: [%{role: "user", content: regression_case["prompt"]}]
    }

    initial = %{chunks: [], bytes: 0, overflow?: false, response_id: nil, terminal: nil}

    with {:ok, accumulator} <- Agent.start_link(fn -> initial end),
         result <- provider.stream(request, &record_event(accumulator, &1)),
         captured <- Agent.get(accumulator, & &1),
         :ok <- Agent.stop(accumulator),
         :ok <- result,
         false <- captured.overflow?,
         {:completed, response_id} <- captured.terminal,
         ^response_id <- captured.response_id do
      response = captured.chunks |> Enum.reverse() |> IO.iodata_to_binary()

      {:ok,
       regression_case
       |> Scorer.score(response)
       |> Map.put("provider_response_id", response_id)
       |> Map.put("response_digest", Canonical.sha256(response))}
    else
      true -> {:error, :response_too_large}
      {:failed, reason} -> {:error, reason}
      :cancelled -> {:error, :cancelled}
      nil -> {:error, :missing_terminal_event}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_provider_event}
    end
  end

  defp record_event(accumulator, {:response_started, response_id}) when is_binary(response_id) do
    Agent.update(accumulator, &%{&1 | response_id: response_id})
  end

  defp record_event(accumulator, {:text_delta, delta}) when is_binary(delta) do
    Agent.update(accumulator, fn captured ->
      next_bytes = captured.bytes + byte_size(delta)

      if next_bytes <= @maximum_response_bytes,
        do: %{captured | chunks: [delta | captured.chunks], bytes: next_bytes},
        else: %{captured | overflow?: true}
    end)
  end

  defp record_event(accumulator, {:response_completed, response_id}),
    do: Agent.update(accumulator, &%{&1 | terminal: {:completed, response_id}})

  defp record_event(accumulator, {:failed, reason}),
    do: Agent.update(accumulator, &%{&1 | terminal: {:failed, reason}})

  defp record_event(accumulator, :cancelled),
    do: Agent.update(accumulator, &%{&1 | terminal: :cancelled})

  defp record_event(_accumulator, _event), do: :ok
end
