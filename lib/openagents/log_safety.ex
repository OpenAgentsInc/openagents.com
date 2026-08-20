defmodule OpenAgents.LogSafety do
  @moduledoc "Content-free acceptance scanner for application and platform log exports."

  @credential_pattern ~r/(?:Bearer\s+[A-Za-z0-9._~+\/-]{8,}|(?:gh[opusr]_|github_pat_|smct_|sig_|oa_pat_|sk-)[A-Za-z0-9._~-]{8,})/i
  @oauth_query_pattern ~r/(?:\?|&)(?:code|state|verifier|access_token)=/i
  @userinfo_pattern ~r|[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@|i
  @scp_userinfo_pattern ~r{(?:^|\s)[^\s/:@]+:[^\s/@]+@[^\s]+}i
  @private_field_pattern ~r/["']?(?:content|messages?|prompt|transcript|memory|raw_arguments|tool_arguments|tool_result|sdp|authorization|cookie|poll_secret|access_token)["']?\s*(?:=>|:|=)\s*([^,\n}]+)/i

  @patterns [
    credential: @credential_pattern,
    oauth_query: @oauth_query_pattern,
    url_userinfo: @userinfo_pattern,
    url_userinfo: @scp_userinfo_pattern
  ]

  @spec scan(Enumerable.t()) :: :ok | {:error, [map()]}
  def scan(lines) do
    findings =
      lines
      |> Stream.with_index(1)
      |> Enum.flat_map(fn {line, line_number} -> findings(line, line_number) end)

    if findings == [], do: :ok, else: {:error, findings}
  end

  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@credential_pattern, &1, "[REDACTED_CREDENTIAL]"))
    |> then(
      &Regex.replace(
        ~r/([?&](?:code|state|verifier|access_token)=)[^&\s]*/i,
        &1,
        "\\1[FILTERED]"
      )
    )
    |> then(&Regex.replace(@userinfo_pattern, &1, "https://[REDACTED_CREDENTIAL]@"))
    |> then(&Regex.replace(@scp_userinfo_pattern, &1, " [REDACTED_CREDENTIAL_URL]"))
    |> then(
      &Regex.replace(@private_field_pattern, &1, fn full, value ->
        String.replace_suffix(full, value, "[FILTERED]")
      end)
    )
  end

  @spec scan_file(Path.t()) :: :ok | {:error, [map()] | :unreadable}
  def scan_file(path) when is_binary(path) do
    path
    |> File.stream!([], :line)
    |> scan()
  rescue
    File.Error -> {:error, :unreadable}
  end

  defp findings(line, line_number) do
    pattern_findings =
      Enum.flat_map(@patterns, fn {kind, pattern} ->
        if Regex.match?(pattern, line), do: [%{kind: kind, line: line_number}], else: []
      end)

    private_field? =
      @private_field_pattern
      |> Regex.scan(line, capture: :all_but_first)
      |> Enum.any?(fn [value] -> not String.contains?(value, "[FILTERED]") end)

    if private_field?,
      do: pattern_findings ++ [%{kind: :private_field, line: line_number}],
      else: pattern_findings
  end
end
