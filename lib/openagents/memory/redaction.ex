defmodule OpenAgents.Memory.Redaction do
  @moduledoc "Conservative whole-field secret rejection and projection withholding."

  @version "sarah.memory.redaction.v1"
  @redacted ~r/(?:\[redacted\]|<redacted>|\*{3,}|•{3,})/iu
  @zero_width ["​", "‌", "‍", "﻿"]

  @type reason ::
          :credential_material
          | :api_token
          | :wallet_seed_material
          | :payment_material
          | :authentication_secret
          | :local_path
          | :encoded_secret_material

  @spec version() :: String.t()
  def version, do: @version

  @spec classify(term()) :: :safe | {:reject, reason()}
  def classify(text) when is_binary(text) do
    if String.valid?(text) do
      text
      |> canonicalize()
      |> detect(true)
    else
      {:reject, :encoded_secret_material}
    end
  end

  def classify(_text), do: {:reject, :credential_material}

  @spec project(term()) :: {:ok, String.t()} | {:withheld, String.t()}
  def project(text) do
    case classify(text) do
      :safe -> {:ok, text}
      {:reject, reason} -> {:withheld, Atom.to_string(reason)}
    end
  end

  defp canonicalize(text) do
    text
    |> :unicode.characters_to_nfkc_binary()
    |> remove_zero_width()
    |> String.replace(~r/[\t\r\n ]+/u, " ")
    |> String.trim()
  end

  defp remove_zero_width(text),
    do: Enum.reduce(@zero_width, text, &String.replace(&2, &1, ""))

  defp detect(text, detect_encoded?) do
    detection_text = String.replace(text, @redacted, "")
    compact = String.replace(detection_text, ~r/\s+/u, "")

    cond do
      wallet_material?(detection_text, compact) -> {:reject, :wallet_seed_material}
      credential_material?(detection_text) -> {:reject, :credential_material}
      api_token?(detection_text, compact) -> {:reject, :api_token}
      payment_material?(detection_text) -> {:reject, :payment_material}
      authentication_secret?(detection_text) -> {:reject, :authentication_secret}
      local_path?(detection_text) -> {:reject, :local_path}
      detect_encoded? and encoded_secret?(detection_text) -> {:reject, :encoded_secret_material}
      true -> :safe
    end
  end

  defp credential_material?(text) do
    Regex.match?(~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/i, text) or
      Regex.match?(
        ~r/\b(?:password|passphrase|client[_ -]?secret|private[_ -]?key)\b\s*[:=]\s*["']?[^\s"',;]{4,}/i,
        text
      ) or
      Regex.match?(
        ~r/\b(?:password|passphrase|client[_ -]?secret)\b\s+is\s+["']?(?:[^\s"',;]{12,}|(?=[^\s"',;]*\d)[^\s"',;]{8,})/i,
        text
      )
  end

  defp api_token?(text, compact) do
    Regex.match?(~r/sk-(?:proj-)?[A-Za-z0-9_-]{20,}/i, compact) or
      Regex.match?(~r/gh[pousr]_[A-Za-z0-9]{20,}/, compact) or
      Regex.match?(~r/AKIA[0-9A-Z]{16}/, compact) or
      Regex.match?(~r/xox[baprs]-[A-Za-z0-9-]{10,}/i, compact) or
      Regex.match?(
        ~r/\b(?:api[_ -]?key|api[_ -]?token)\b\s*[:=]\s*["']?[^\s"',;]{6,}/i,
        text
      )
  end

  defp wallet_material?(text, compact) do
    Regex.match?(
      ~r/\b(?:seed[_ -]?phrase|mnemonic|wallet[_ -]?secret|wallet[_ -]?private[_ -]?key)\b\s*(?::|=|is)\s*\S+/i,
      text
    ) or Regex.match?(~r/(?:^|[^0-9a-f])0x[0-9a-f]{64}(?:$|[^0-9a-f])/i, compact)
  end

  # The card-number scan requires token boundaries: a digit run embedded in a
  # longer alphanumeric token (a sha256 provenance ref, a UUID fragment, a
  # commit hash) is not a card, but a 13-19 digit slice of one passes Luhn
  # roughly one time in ten — which made portable imports fail by hash
  # lottery whenever an installation ref happened to contain such a run.
  defp payment_material?(text) do
    Regex.match?(~r/\b(?:cvv|cvc|card[_ -]?number|routing[_ -]?number)\b\s*[:=]\s*\d{3,}/i, text) or
      Regex.scan(~r/(?<![0-9A-Za-z])(?:\d[ -]?){12,18}\d(?![0-9A-Za-z])/, text)
      |> List.flatten()
      |> Enum.any?(&luhn_candidate?/1)
  end

  defp authentication_secret?(text) do
    Regex.match?(~r/\bBearer\s+[A-Za-z0-9._~+\/-]{12,}/i, text) or
      Regex.match?(
        ~r/\b(?:token|access[_ -]?token|refresh[_ -]?token|auth[_ -]?token|session[_ -]?cookie|session[_ -]?secret)\b\s*[:=]\s*["']?[^\s"',;]{6,}/i,
        text
      )
  end

  defp local_path?(text) do
    Regex.match?(
      ~r/(?:^|[\s"'])(?:~\/|\/Users\/|\/home\/|\/var\/|\/etc\/|\/tmp\/|\/opt\/|file:\/\/)/i,
      text
    ) or
      Regex.match?(~r/(?:^|[\s"'])[A-Z]:\\(?:Users|Windows|Program Files)\\/i, text)
  end

  defp encoded_secret?(text) do
    encoded_candidates(text)
    |> Enum.any?(fn candidate ->
      candidate
      |> decode_candidates()
      |> Enum.any?(fn decoded ->
        printable?(decoded) and detect(canonicalize(decoded), false) != :safe
      end)
    end)
  end

  defp encoded_candidates(text) do
    base64 =
      Regex.scan(~r/(?<![A-Za-z0-9+\/_-])[A-Za-z0-9+\/_-]{16,}={0,2}(?![A-Za-z0-9+\/_-])/, text)

    hex = Regex.scan(~r/(?<![0-9a-f])[0-9a-f]{32,}(?![0-9a-f])/i, text)
    (base64 ++ hex) |> List.flatten() |> Enum.uniq()
  end

  defp decode_candidates(candidate) do
    standard = decode64(candidate, &Base.decode64/2)
    url = decode64(candidate, &Base.url_decode64/2)
    hex = if rem(byte_size(candidate), 2) == 0, do: decode16(candidate), else: []
    Enum.uniq(standard ++ url ++ hex)
  end

  defp decode64(candidate, decoder) do
    case decoder.(candidate, padding: false) do
      {:ok, decoded} -> [decoded]
      :error -> []
    end
  end

  defp decode16(candidate) do
    case Base.decode16(candidate, case: :mixed) do
      {:ok, decoded} -> [decoded]
      :error -> []
    end
  end

  defp printable?(text) do
    String.valid?(text) and byte_size(text) in 4..500 and
      text
      |> String.to_charlist()
      |> Enum.all?(&(&1 in [9, 10, 13] or &1 in 32..126))
  end

  defp luhn_candidate?(candidate) do
    digits =
      candidate
      |> String.replace(~r/\D/, "")
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)

    length(digits) in 13..19 and
      digits
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, index}, sum ->
        adjusted =
          if rem(index, 2) == 1 do
            doubled = digit * 2
            if doubled > 9, do: doubled - 9, else: doubled
          else
            digit
          end

        sum + adjusted
      end)
      |> rem(10) == 0
  end
end
