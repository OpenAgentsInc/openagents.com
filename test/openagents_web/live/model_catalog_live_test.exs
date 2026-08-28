defmodule OpenAgentsWeb.ModelCatalogLiveTest do
  @moduledoc """
  `/models`: the half of "pricing visible before spend" a person can read
  (#200, METER-001).

  The endpoint answered the CLI; nothing rendered the catalog for a human. What
  matters here is not that the page exists but that it carries the same pricing
  truth as the endpoint does: an unpriced lane shows the word rather than
  `$0.00`, while the declared Coder Free router shows its zero rate.
  """
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Inference.Models
  alias OpenAgents.UnpricedLane

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp reader(conn, handle), do: signed_in(conn, github_user(handle))

  defp unpriced_id, do: UnpricedLane.id()

  # No shipped lane is unpriced since `gpt-5.6-luna` was withdrawn, so the
  # tests that read the unpriced rendering admit a lane of their own.
  defp admit_unpriced_lane do
    previous = UnpricedLane.admit!()
    on_exit(fn -> UnpricedLane.restore(previous) end)
    :ok
  end

  test "every model this deployment serves has a row", %{conn: conn} do
    {:ok, view, _html} = live(reader(conn, "model-catalog-rows"), ~p"/models")

    assert has_element?(view, "#model-catalog-table")

    for id <- Models.ids() do
      assert has_element?(view, ~s([id="model-#{id}"])), "no row for #{id}"
    end
  end

  test "an unpriced lane shows the word, never a zero", %{conn: conn} do
    :ok = admit_unpriced_lane()
    id = unpriced_id()
    {:ok, view, _html} = live(reader(conn, "model-catalog-unpriced"), ~p"/models")

    assert view |> element(~s([id="model-basis-#{id}"])) |> render() =~ "unpriced"
    assert view |> element(~s([id="model-input-rate-#{id}"])) |> render() =~ "Unpriced"
    assert view |> element(~s([id="model-output-rate-#{id}"])) |> render() =~ "Unpriced"

    refute view |> element(~s([id="model-input-rate-#{id}"])) |> render() =~ "$0.00"
    refute view |> element(~s([id="model-output-rate-#{id}"])) |> render() =~ "$0.00"
  end

  test "a lane with rates publishes them and names the table they came from", %{conn: conn} do
    {:ok, view, _html} = live(reader(conn, "model-catalog-priced"), ~p"/models")

    # 750_000 microUSD per million tokens is $0.75 per million tokens, the
    # introductory Standard paid-tier rate still in force at test `pricing_now`.
    assert view |> element(~s([id="model-input-rate-gemini-3.7-flash"])) |> render() =~ "$0.75"
    assert view |> element(~s([id="model-basis-gemini-3.7-flash"])) |> render() =~ "declared"

    assert view |> element(~s([id="model-pricing-id-gemini-3.7-flash"])) |> render() =~
             "declared.gemini-3.7-flash.intro-through-2026-12-31.v1"
  end

  test "the declared free router is billable at zero", %{conn: conn} do
    {:ok, view, _html} = live(reader(conn, "model-catalog-free"), ~p"/models")

    refute has_element?(view, "#model-catalog-not-billable")
    assert view |> element(~s([id="model-basis-openrouter/free"])) |> render() =~ "declared"
    assert view |> element(~s([id="model-input-rate-openrouter/free"])) |> render() =~ "$0.00"
    assert view |> element(~s([id="model-output-rate-openrouter/free"])) |> render() =~ "$0.00"
  end

  test "the billable notice is derived from the catalog, not written into the page",
       %{conn: conn} do
    :ok = admit_unpriced_lane()
    previous = Application.fetch_env!(:openagents, :model_catalog)

    declared =
      Enum.map(previous, fn
        %{id: "gemini-3.7-flash"} = entry ->
          Map.put(entry, :pricing, %{
            id: "declared.test.v1",
            source: :declared,
            input_per_million_tokens: 3_000_000,
            output_per_million_tokens: 15_000_000
          })

        entry ->
          entry
      end)

    Application.put_env(:openagents, :model_catalog, declared)
    on_exit(fn -> Application.put_env(:openagents, :model_catalog, previous) end)

    {:ok, view, _html} = live(reader(conn, "model-catalog-declared"), ~p"/models")

    refute has_element?(view, "#model-catalog-not-billable")
    assert view |> element(~s([id="model-basis-gemini-3.7-flash"])) |> render() =~ "declared"
    assert view |> element(~s([id="model-input-rate-gemini-3.7-flash"])) |> render() =~ "$3.00"

    # The lane with no rates is untouched by another lane becoming billable.
    assert view |> element(~s([id="model-input-rate-#{unpriced_id()}"])) |> render() =~ "Unpriced"
  end

  test "an anonymous visitor is sent to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/models")
    refute path == ~p"/models"
  end
end
