defmodule OpenAgentsWeb.ModelCatalogControllerTest do
  @moduledoc """
  `GET /api/v1/models`: the typed catalog a client selects from (PROVIDER-002).

  The catalog is what makes model selection honest: the CLI renders this list,
  the thread admission refuses against the same list, and a lane whose
  credential is not configured is listed as unavailable rather than omitted or
  silently substituted.
  """
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Inference.Models
  alias OpenAgents.UnpricedLane

  # No shipped lane is unpriced since `gpt-5.6-luna` was withdrawn, so the
  # tests that read the unpriced projection admit a lane of their own.
  defp admit_unpriced_lane do
    previous = UnpricedLane.admit!()
    on_exit(fn -> UnpricedLane.restore(previous) end)
    :ok
  end

  test "the catalog lists every served model in its typed shape", %{conn: conn} do
    body =
      conn
      |> put_chat_api_token("model-catalog")
      |> get(~p"/api/v1/models")
      |> json_response(200)

    assert body["default"] == Models.default_id()
    assert Enum.map(body["models"], & &1["id"]) == Models.ids()

    for entry <- body["models"] do
      assert Enum.all?(
               ~w(availability context_window default id max_output provider),
               &(&1 in Map.keys(entry))
             )

      assert is_binary(entry["provider"]) and entry["provider"] != ""
      assert is_integer(entry["context_window"]) and entry["context_window"] > 0
      assert is_integer(entry["max_output"]) and entry["max_output"] > 0
      # Every test lane's adapter reports a configured credential.
      assert entry["availability"] == "available"

      if entry["pricing"] do
        assert Enum.all?(
                 ~w(input_per_million_tokens output_per_million_tokens),
                 &(&1 in Map.keys(entry["pricing"]))
               )

        assert is_integer(entry["pricing"]["input_per_million_tokens"])
        assert is_integer(entry["pricing"]["output_per_million_tokens"])
      end
    end

    assert [default_entry] = Enum.filter(body["models"], & &1["default"])
    assert default_entry["id"] == body["default"]
  end

  test "a lane without a configured credential is listed unavailable, not omitted", %{conn: conn} do
    # A lane on the OpenAI adapter, because both shipped models sit on the
    # Vercel gateway and this test is about a lane going dark *without* taking
    # the default with it: "served here, not currently configured" has to be
    # distinguishable from "not served here" while the deployment still
    # answers.
    :ok = admit_unpriced_lane()
    previous = Application.get_env(:openagents, :provider)

    Application.put_env(:openagents, :provider, OpenAgents.Providers.UnconfiguredTestProvider)

    on_exit(fn -> Application.put_env(:openagents, :provider, previous) end)

    body =
      conn
      |> put_chat_api_token("model-catalog-unavailable")
      |> get(~p"/api/v1/models")
      |> json_response(200)

    # The model stays in the list — "served here, not currently configured"
    # is different information from "not served here" — and only its
    # availability changes.
    assert Enum.map(body["models"], & &1["id"]) == Models.ids()

    dark = Enum.find(body["models"], &(&1["id"] == UnpricedLane.id()))

    assert dark["availability"] == "unavailable"

    default_entry = Enum.find(body["models"], &(&1["id"] == body["default"]))
    assert default_entry["availability"] == "available"
  end

  test "the catalog requires the same bearer as threads", %{conn: conn} do
    body =
      conn
      |> get(~p"/api/v1/models")
      |> json_response(401)

    assert body["code"] == "unauthenticated"
  end

  describe "pricing in the published catalog" do
    test "a priced model exposes its per-million-token rates", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("model-catalog-priced")
        |> get(~p"/api/v1/models")
        |> json_response(200)

      gemini = Enum.find(body["models"], &(&1["id"] == "gemini-3.7-flash"))

      assert %{
               "pricing" => %{
                 "input_per_million_tokens" => 750_000,
                 "output_per_million_tokens" => 3_750_000,
                 "cached_input_per_million_tokens" => 75_000
               }
             } = gemini
    end

    test "an unpriced model has no pricing key", %{conn: conn} do
      :ok = admit_unpriced_lane()

      body =
        conn
        |> put_chat_api_token("model-catalog-unpriced")
        |> get(~p"/api/v1/models")
        |> json_response(200)

      unpriced = Enum.find(body["models"], &(&1["id"] == UnpricedLane.id()))
      refute Map.has_key?(unpriced, "pricing")
    end

    test "every entry says in one word whether its price can be trusted", %{conn: conn} do
      :ok = admit_unpriced_lane()

      body =
        conn
        |> put_chat_api_token("model-catalog-basis")
        |> get(~p"/api/v1/models")
        |> json_response(200)

      # A client that forgets to check for a missing `pricing` key would read
      # an unknown price as no price. This word is the positive signal, and it
      # is present on every entry rather than only the awkward ones (METER-001).
      assert Enum.all?(
               body["models"],
               &(&1["pricing_basis"] in ~w(declared provisional unpriced))
             )

      assert Enum.find(body["models"], &(&1["id"] == UnpricedLane.id()))["pricing_basis"] ==
               "unpriced"

      gemini = Enum.find(body["models"], &(&1["id"] == "gemini-3.7-flash"))
      assert gemini["pricing_basis"] == "declared"
      assert gemini["pricing"]["basis"] == "declared"
      assert gemini["pricing"]["id"] == "declared.gemini-3.7-flash.intro-through-2026-12-31.v1"
    end
  end
end
