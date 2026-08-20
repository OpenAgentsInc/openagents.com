defmodule OpenAgentsWeb.ControllerPairingController do
  @moduledoc """
  Device-style pairing API for the sarah-computer-controller CLI.

  `create` is unauthenticated: it registers a pending pairing and returns a
  short code the signed-in owner approves in the browser. `show` is polled by
  the CLI with the poll secret and hands the machine token over exactly once.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Computer
  alias OpenAgents.Machines

  plug :verify_enabled
  plug :put_no_store

  def create(conn, params) do
    attributes = %{
      "name" => params["name"],
      "tier" => params["tier"] || "probe",
      "platform" => bounded(params["platform"]),
      "agent_version" => bounded(params["agent_version"]),
      "roots" => bounded_roots(params["roots"])
    }

    case Machines.start_pairing(attributes) do
      {:ok, %{pairing: pairing, code: code, poll_secret: poll_secret}} ->
        json(conn, %{
          "pairing_id" => pairing.id,
          "code" => format_code(code),
          "poll_secret" => poll_secret,
          "verify_url" => url(~p"/computers"),
          "expires_at" => DateTime.to_iso8601(pairing.expires_at),
          "interval_seconds" => 3
        })

      {:error, _changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => "invalid_pairing"})
    end
  end

  def show(conn, %{"id" => pairing_id}) do
    poll_secret = get_req_header(conn, "x-pairing-secret") |> List.first("")

    case Machines.claim_pairing(pairing_id, poll_secret) do
      {:ok, %{token: token, machine_id: machine_id, name: name}} ->
        json(conn, %{
          "status" => "approved",
          "machine_id" => machine_id,
          "name" => name,
          "token" => token
        })

      {:error, :pairing_pending} ->
        json(conn, %{"status" => "pending"})

      {:error, :pairing_expired} ->
        conn |> put_status(:gone) |> json(%{"status" => "expired"})

      {:error, _reason} ->
        conn |> put_status(:not_found) |> json(%{"error" => "pairing_not_found"})
    end
  end

  defp verify_enabled(conn, _options) do
    if Computer.enabled?() do
      conn
    else
      conn
      |> put_status(:not_found)
      |> json(%{"error" => "computer_controller_disabled"})
      |> halt()
    end
  end

  defp put_no_store(conn, _options), do: put_resp_header(conn, "cache-control", "no-store")

  defp bounded(value) when is_binary(value), do: String.slice(value, 0, 40)
  defp bounded(_value), do: nil

  defp bounded_roots(roots) when is_list(roots) do
    roots
    |> Enum.filter(&is_binary/1)
    |> Enum.take(16)
    |> Enum.map(&String.slice(&1, 0, 512))
  end

  defp bounded_roots(_roots), do: []

  defp format_code(<<first::binary-size(4), second::binary-size(4)>>),
    do: first <> "-" <> second

  defp format_code(code), do: code
end
