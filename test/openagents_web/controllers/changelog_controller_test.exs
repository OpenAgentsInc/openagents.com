defmodule OpenAgentsWeb.ChangelogControllerTest do
  @moduledoc """
  The `/api/changelog` controller (#138, TRANSPARENCY-001): the public,
  schema-versioned projection is redacted per the requester's viewer and the
  entry's transparency tier.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Changelog

  setup do
    :persistent_term.erase({OpenAgents.Changelog, :cache})
    on_exit(fn -> :persistent_term.erase({OpenAgents.Changelog, :cache}) end)
    :ok
  end

  defp full_sha(prefix), do: String.pad_trailing(prefix, 40, "0")

  describe "GET /api/changelog" do
    test "redacts dark-tier trace_ref, trace_digest, and detail", %{conn: conn} do
      {:ok, _} =
        Changelog.record(%{
          repo: "openagents.com",
          sha: full_sha("feed0201"),
          summary: "Dark tier entry",
          category: "ui",
          source: "operator",
          entry_at: DateTime.utc_now(),
          visibility: "l2",
          transparency_tier: "dark",
          trace_ref: "trace:v1:dark",
          trace_digest: "sha256:dark",
          detail: %{"note" => "hidden"}
        })

      conn = get(conn, ~p"/api/changelog")
      payload = json_response(conn, 200)

      assert [entry] = Enum.filter(payload["entries"], &(&1["summary"] == "Dark tier entry"))
      assert entry["trace_ref"] == nil
      assert entry["trace_digest"] == nil
      assert entry["detail"] == %{}
    end

    test "keeps pulse-tier trace_ref and trace_digest but redacts detail", %{conn: conn} do
      {:ok, _} =
        Changelog.record(%{
          repo: "openagents.com",
          sha: full_sha("feed0202"),
          summary: "Pulse tier entry",
          category: "ui",
          source: "operator",
          entry_at: DateTime.utc_now(),
          visibility: "l2",
          transparency_tier: "pulse",
          trace_ref: "trace:v1:pulse",
          trace_digest: "sha256:pulse",
          detail: %{"note" => "hidden"}
        })

      conn = get(conn, ~p"/api/changelog")
      payload = json_response(conn, 200)

      assert [entry] = Enum.filter(payload["entries"], &(&1["summary"] == "Pulse tier entry"))
      assert entry["trace_ref"] == "trace:v1:pulse"
      assert entry["trace_digest"] == "sha256:pulse"
      assert entry["detail"] == %{}
    end
  end
end
