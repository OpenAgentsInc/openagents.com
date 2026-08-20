defmodule OpenAgentsWeb.Plugs.StatusProbeCompat do
  @moduledoc """
  Deprecation shim for machine pollers of `GET /status`.

  `/status` is the public network-status page, but legacy pollers hit the old
  JSON contract on a ~15s cadence. Anything that does not ask for HTML —
  probes, curl, uptime monitors (`Accept: application/json`, `*/*`, or none),
  or an explicit `?format=json` — still gets the legacy DB-checked payload,
  byte-shaped like before: `{"status":"ok","revision":...}` (503 on DB
  failure). Browsers asking for `text/html` fall through to the LiveView.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    if status_path?(conn) and not wants_html?(conn) do
      conn
      |> legacy_health_response()
      |> halt()
    else
      conn
    end
  end

  defp status_path?(conn), do: conn.method == "GET" and conn.request_path == "/status"

  defp wants_html?(conn) do
    format = conn.query_params["format"] || conn.params["format"]
    accept = conn |> get_req_header("accept") |> Enum.join(",")

    cond do
      format == "json" -> false
      String.contains?(accept, "text/html") -> true
      true -> false
    end
  end

  defp legacy_health_response(conn) do
    case OpenAgents.Repo.query("SELECT 1") do
      {:ok, _result} ->
        json_response(conn, 200, %{status: "ok", revision: OpenAgents.BuildInfo.revision()})

      {:error, _reason} ->
        json_response(conn, 503, %{status: "unavailable"})
    end
  rescue
    _error -> json_response(conn, 503, %{status: "unavailable"})
  end

  defp json_response(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Phoenix.json_library().encode!(payload))
  end
end
