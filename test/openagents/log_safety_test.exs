defmodule OpenAgents.LogSafetyTest do
  use ExUnit.Case, async: true

  alias OpenAgents.LogSafety

  test "content-free operational lines and filtered parameters pass" do
    assert :ok =
             LogSafety.scan([
               "request_id=abc Sent 200 in 14ms\n",
               "voice_operation {\"event\":\"connected\",\"total_tokens\":42}\n",
               "Parameters: %{\"code\" => \"[FILTERED]\", \"content\" => \"[FILTERED]\"}\n"
             ])
  end

  test "credential, OAuth query, URL userinfo, and private content fields fail without echoing values" do
    lines = [
      "GET /auth/github/callback?code=oauth-secret&state=state-secret\n",
      "authorization: Bearer smct_machine-secret-value\n",
      "clone ecto://x:database-secret@database/openagents\n",
      "push operator:forge-secret@mirror.example:openagents.com.git\n",
      ~s|payload {"raw_arguments":"private tool value"}\n|,
      ~s|event=%{transcript: "private spoken value"}\n|
    ]

    assert {:error, findings} = LogSafety.scan(lines)

    kinds = Enum.frequencies_by(findings, & &1.kind)
    assert kinds == %{credential: 1, oauth_query: 1, private_field: 3, url_userinfo: 2}

    refute inspect(findings) =~ "secret"
    refute inspect(findings) =~ "private tool value"
    refute inspect(findings) =~ "private spoken value"
  end

  test "redaction removes credentials and private fields before bounded output is receipted" do
    unsafe =
      ~s|clone https://x:forge-secret@forge/repo?code=oauth-code | <>
        ~s|authorization: Bearer smct_machine-secret {"content":"private prompt"}|

    redacted = LogSafety.redact(unsafe)

    refute redacted =~ "forge-secret"
    refute redacted =~ "oauth-code"
    refute redacted =~ "smct_machine-secret"
    refute redacted =~ "private prompt"
    assert redacted =~ "[REDACTED_CREDENTIAL]"
    assert redacted =~ "[FILTERED]"
  end

  test "logger calls do not interpolate raw exception messages or inspected failure payloads" do
    source =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    refute Regex.match?(
             ~r/Logger\.(?:debug|info|notice|warning|error)[\s\S]{0,200}(?:Exception\.message|inspect\((?:reason|error|build|output)\))/,
             source
           )
  end
end
