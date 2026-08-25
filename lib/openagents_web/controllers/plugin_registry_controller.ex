defmodule OpenAgentsWeb.PluginRegistryController do
  @moduledoc """
  Public plugin registry discovery for the CLI.

  The index lists validated manifests and leaves semantic selection to the
  caller. Exact-name lookup is available for invocation.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Plugins.Index

  def index(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=60")
    |> json(%{"plugins" => Enum.map(Index.list(), &Index.to_map/1)})
  end

  def show(conn, %{"name" => name}) do
    case Index.get(name) do
      {:ok, entry} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=60")
        |> json(%{"plugin" => Index.to_map(entry)})

      {:error, :not_found} ->
        OpenAgentsWeb.ApiError.not_found(conn)
    end
  end
end
