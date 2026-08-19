defmodule OpenAgents.Memory.Consent do
  @moduledoc "Deterministic current-message consent checks for profile-memory writes."

  @remember ~r/\A\s*(?:please\s+)?(?:remember|store|save)\s+(?:that\s+)?(.+?)\s*[.!]?\s*\z/iu
  @forget ~r/\A\s*(?:please\s+)?forget\s+(?:that\s+)?(.+?)\s*[.!]?\s*\z/iu

  def remember(message, claim, context_consent \\ nil) do
    with {:ok, submitted} <- bounded(claim),
         {:ok, evidence} <- remember_evidence(message, context_consent),
         true <- equivalent?(submitted, evidence.claim) do
      {:ok, Map.from_struct(evidence)}
    else
      false -> {:error, :memory_consent_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def forget(message, mode, target, context_consent \\ nil) do
    with {:ok, evidence} <- forget_evidence(message, mode, context_consent),
         true <- forget_matches?(mode, target, evidence.claim) do
      {:ok, Map.from_struct(evidence)}
    else
      false -> {:error, :memory_consent_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remember_evidence(message, context_consent) when is_binary(message) do
    case Regex.run(@remember, message, capture: :all_but_first) do
      [claim] -> evidence("current_message", "remember", claim)
      _missing -> external_evidence(context_consent, "remember")
    end
  end

  defp remember_evidence(_message, consent), do: external_evidence(consent, "remember")

  defp forget_evidence(message, mode, context_consent) when is_binary(message) do
    normalized = normalize(message)

    cond do
      mode == "all" and forget_all?(normalized) ->
        evidence("current_message", "forget", "all")

      mode == "category" ->
        case Regex.run(
               ~r/\A(?:please )?forget (?:all |everything (?:in|from) )?(?:the )?([a-z]+)(?: category| memories)?\z/iu,
               normalized,
               capture: :all_but_first
             ) do
          [category] -> evidence("current_message", "forget", category)
          _missing -> external_evidence(context_consent, "forget")
        end

      mode == "record" ->
        case Regex.run(@forget, message, capture: :all_but_first) do
          [claim] -> evidence("current_message", "forget", claim)
          _missing -> external_evidence(context_consent, "forget")
        end

      true ->
        external_evidence(context_consent, "forget")
    end
  end

  defp forget_evidence(_message, _mode, consent), do: external_evidence(consent, "forget")

  defp external_evidence(
         %{"kind" => kind, "operation" => operation, "claim" => claim},
         operation
       )
       when kind in ["exact_confirmation", "first_party_ui"] do
    evidence(kind, operation, claim)
  end

  defp external_evidence(_consent, _operation), do: {:error, :memory_consent_required}

  defp evidence(kind, operation, claim) do
    with {:ok, bounded_claim} <- bounded(claim) do
      {:ok, %{__struct__: Evidence, kind: kind, operation: operation, claim: bounded_claim}}
    end
  end

  @forget_all ~r/\A(?:please )?(?:forget|erase|delete|clear|wipe) (?:everything|all(?: (?:of )?(?:your|the|my))?(?: stored)?(?: (?:memories|facts|profile memories))?)(?: (?:that )?(?:you(?:['’]ve| have)?) (?:stored|saved|remember(?:ed)?|know|learned))?(?: about me| about this browser| in this browser| for this browser| for me)?\z/u

  defp forget_all?(normalized), do: Regex.match?(@forget_all, normalized)

  defp forget_matches?("all", _target, "all"), do: true
  defp forget_matches?(_mode, target, claim), do: equivalent?(target, claim)

  defp equivalent?(left, right), do: normalize(left) == normalize(right)

  defp bounded(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.trim_trailing(".") |> String.trim()
    if byte_size(normalized) in 1..500, do: {:ok, normalized}, else: {:error, :invalid_claim}
  end

  defp bounded(_value), do: {:error, :invalid_claim}

  defp normalize(value) do
    value
    |> String.normalize(:nfkc)
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.trim()
    |> String.downcase()
  end

  defmodule Evidence do
    @moduledoc false
    defstruct [:kind, :operation, :claim]
  end
end
