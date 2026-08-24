defmodule OpenAgentsWeb.ModelCatalogControllerTest do
  @moduledoc """
  `GET /api/v3/models`: the typed catalog a client selects from (PROVIDER-002).

  The catalog is what makes model selection honest: the CLI renders this list,
  the thread admission refuses against the same list, and a lane whose
  credential is not configured is listed as unavailable rather than omitted or
  silently substituted.
  """
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Inference.Models

  test "the catalog lists every served model in its typed shape", %{conn: conn} do
    body =
      conn
      |> put_chat_api_token("model-catalog")
      |> get(~p"/api/v3/models")
      |> json_response(200)

    assert body["default"] == Models.default_id()
    assert Enum.map(body["models"], & &1["id"]) == Models.ids()

    for entry <- body["models"] do
      assert Enum.sort(Map.keys(entry)) ==
               ~w(availability context_window default id max_output provider)

      assert is_binary(entry["provider"]) and entry["provider"] != ""
      assert is_integer(entry["context_window"]) and entry["context_window"] > 0
      assert is_integer(entry["max_output"]) and entry["max_output"] > 0
      # Every test lane's adapter reports a configured credential.
      assert entry["availability"] == "available"
    end

    assert [default_entry] = Enum.filter(body["models"], & &1["default"])
    assert default_entry["id"] == body["default"]
  end

  test "a lane without a configured credential is listed unavailable, not omitted", %{conn: conn} do
    previous = Application.get_env(:openagents, :openrouter_provider)

    Application.put_env(
      :openagents,
      :openrouter_provider,
      OpenAgents.Providers.UnconfiguredTestProvider
    )

    on_exit(fn -> Application.put_env(:openagents, :openrouter_provider, previous) end)

    body =
      conn
      |> put_chat_api_token("model-catalog-unavailable")
      |> get(~p"/api/v3/models")
      |> json_response(200)

    # The model stays in the list — "served here, not currently configured"
    # is different information from "not served here" — and only its
    # availability changes.
    assert Enum.map(body["models"], & &1["id"]) == Models.ids()

    ox_alpha = Enum.find(body["models"], &(&1["id"] == "ox-alpha"))
    assert ox_alpha["availability"] == "unavailable"

    default_entry = Enum.find(body["models"], &(&1["id"] == body["default"]))
    assert default_entry["availability"] == "available"
  end

  test "the catalog requires the same bearer as threads", %{conn: conn} do
    body =
      conn
      |> get(~p"/api/v3/models")
      |> json_response(401)

    assert body["code"] == "unauthenticated"
  end
end
