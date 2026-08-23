defmodule OpenAgents.DoNotBuildRegister do
  @moduledoc """
  Reads and screens proposals against the durable do-not-build register.

  Matching uses explicit multi-word phrases from the register. It does not
  expand keywords, stem words, or infer semantic similarity, so unrelated work
  is not blocked because it mentions a product name.
  """

  alias OpenAgents.Analytics

  @register_path "priv/api-contracts/do-not-build-v1.json"
  @decision_states ~w(retired deferred rejected superseded)

  @doc "The decoded and validated public register."
  def load do
    with {:ok, bytes} <- File.read(register_file()),
         {:ok, register} <- Jason.decode(bytes),
         :ok <- validate(register) do
      {:ok, register}
    end
  end

  @doc "The register entries, raising when the committed contract is invalid."
  def entries do
    {:ok, register} = load()
    register["entries"]
  end

  @doc "The first precise register match for a proposal, or nil."
  def match(proposal) do
    text = proposal_text(proposal)

    Enum.find(entries(), fn entry ->
      Enum.any?(entry["match_phrases"], &String.contains?(text, normalize(&1)))
    end)
  end

  @doc """
  Screens a FastFollow backlog proposal.

  A match is suppressed and recorded without proposal text. New evidence and
  an explicit decision record move the result to manual register review; they
  do not silently override the committed decision.
  """
  def screen_fast_follow(proposal, opts \\ []) when is_list(opts) do
    case match(proposal) do
      nil ->
        :allow

      entry ->
        if reconsideration_ready?(opts) do
          {:review_required, entry}
        else
          record_suppression(entry, proposal)
          {:suppressed, entry}
        end
    end
  end

  @doc "Validates the public contract and its append-only decision history."
  def validate(%{
        "contract" => "openagents.do-not-build.v1",
        "version" => 1,
        "decision_states" => @decision_states,
        "entries" => entries
      })
      when is_list(entries) do
    with :ok <- validate_unique_ids(entries),
         :ok <- validate_entries(entries) do
      :ok
    end
  end

  def validate(_register), do: {:error, :invalid_contract}

  defp validate_unique_ids(entries) do
    ids = Enum.map(entries, & &1["id"])

    if length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: {:error, :duplicate_ids}
  end

  defp validate_entries(entries) do
    if Enum.all?(entries, &valid_entry?/1),
      do: :ok,
      else: {:error, :invalid_entry}
  end

  defp valid_entry?(%{
         "id" => id,
         "retired_scope" => scope,
         "match_phrases" => phrases,
         "current" => current,
         "history" => history
       })
       when is_binary(id) and is_binary(scope) and is_list(phrases) and is_map(current) and
              is_list(history) and history != [] do
    valid_phrases?(phrases) and valid_decision?(current) and List.last(history) == current and
      Enum.all?(history, &valid_decision?/1)
  end

  defp valid_entry?(_entry), do: false

  defp valid_phrases?(phrases) do
    phrases != [] and
      Enum.all?(phrases, fn phrase ->
        is_binary(phrase) and String.length(phrase) >= 8 and
          phrase |> String.split() |> length() >= 2
      end)
  end

  defp valid_decision?(%{
         "state" => state,
         "decision_date" => date,
         "evidence" => evidence,
         "violated_principle" => principle,
         "replacement_path" => replacement,
         "owner" => owner,
         "reconsideration_trigger" => trigger,
         "decision_record" => record
       }) do
    state in @decision_states and valid_date?(date) and non_empty_list?(evidence) and
      Enum.all?(evidence, &valid_evidence?/1) and
      Enum.all?([principle, replacement, owner, trigger, record], &non_empty_string?/1)
  end

  defp valid_decision?(_decision), do: false

  defp valid_evidence?(%{"source" => source, "summary" => summary}),
    do: non_empty_string?(source) and non_empty_string?(summary)

  defp valid_evidence?(_evidence), do: false

  defp valid_date?(date) when is_binary(date), do: match?({:ok, _}, Date.from_iso8601(date))
  defp valid_date?(_date), do: false

  defp non_empty_list?(value), do: is_list(value) and value != []
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp reconsideration_ready?(opts) do
    non_empty_string?(Keyword.get(opts, :new_evidence)) and
      non_empty_string?(Keyword.get(opts, :decision_record))
  end

  defp record_suppression(entry, proposal) do
    Analytics.capture(
      "fast_follow_proposal_suppressed",
      Analytics.system_distinct_id("fast_follow"),
      %{
        "register_id" => entry["id"],
        "decision_state" => entry["current"]["state"],
        "proposal_fingerprint" => fingerprint(proposal)
      }
    )
  end

  defp fingerprint(proposal) do
    proposal
    |> proposal_text()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp proposal_text(proposal) when is_binary(proposal), do: normalize(proposal)

  defp proposal_text(proposal) when is_map(proposal) do
    [proposal[:title], proposal["title"], proposal[:body], proposal["body"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> normalize()
  end

  defp proposal_text(_proposal), do: ""

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp register_file, do: Application.app_dir(:openagents, @register_path)
end
