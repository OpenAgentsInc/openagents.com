defmodule OpenAgentsWeb.ModelCatalogLive do
  @moduledoc """
  `/models`: what each lane costs, and whether the figure can be trusted,
  before anything spends against it (#200, METER-001).

  The contract asks that per-model pricing be readable by the CLI **and** by
  the web before any spend. `GET /api/v1/models` answered the first half; a
  person could not read it. This page is that endpoint's other reader: it
  renders `OpenAgents.Inference.Models.catalog/0` directly, so the page and the
  endpoint cannot come to disagree about what this deployment serves or what it
  charges.

  Same principal as the endpoint, deliberately. `GET /api/v1/models` sits in
  the thread scope because the catalog names what a grant can be minted for, so
  the caller who can open a thread is the caller who reads it — and the reader
  of this page is the person who can open one. "Before spend" still holds:
  spending here requires an account.

  Two rules govern every cell. A lane with no declared rates shows the word
  `Unpriced`, never `$0.00` — the deployment not knowing what a call cost is a
  different fact from the call having cost nothing. And a rate this deployment
  wrote to make itself run is labelled `provisional`, so nobody reads a working
  figure as a price. The Coder Free lane declares zero rates because its router
  only selects free models; the other listed rates remain provisional.

  Availability is `Models.availability/1`, the same word the endpoint
  publishes, refreshed on a slow tick: a page about what a lane costs that
  showed a dead lane as available would be lying about the more urgent half.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Inference.Models

  @tick_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     socket
     |> assign(:page_title, "Models · OpenAgents")
     |> assign_catalog()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, assign_catalog(socket)}
  end

  defp assign_catalog(socket) do
    models = Models.catalog()

    socket
    |> assign(:models, models)
    |> assign(:default_id, Models.default_id())
    |> assign(:billable?, Enum.any?(models, &(&1["pricing_basis"] == "declared")))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <main id="model-catalog" class="mx-auto w-full max-w-5xl space-y-6 px-4 py-10">
        <.header>
          Models
          <:subtitle>
            Every model this deployment serves, what each lane charges, and on whose
            authority. The same catalog
            <.kbd>GET /api/v1/models</.kbd>
            publishes.
          </:subtitle>
        </.header>

        <.alert
          :if={!@billable?}
          id="model-catalog-not-billable"
          variant={:warning}
          label="Nothing here is billable"
        >
          No lane on this deployment carries rates read off a provider's price page, so
          every figure below is a working number and nothing bills from any of them.
          A lane marked <strong>Unpriced</strong>
          has no rates at all: its calls record no cost, and the sessions that touch it
          report no total rather than a zero.
        </.alert>

        <.table id="model-catalog-table" rows={@models} row_id={&"model-#{&1["id"]}"}>
          <:col :let={model} label="Model">
            <span class="font-mono text-xs">{model["id"]}</span>
            <.badge :if={model["id"] == @default_id} class="ml-2" variant={:dim}>default</.badge>
            <p class="mt-0.5 text-xs text-muted-foreground">{model["provider"]} lane</p>
          </:col>

          <:col :let={model} label="Availability">
            <.badge
              id={"model-availability-#{model["id"]}"}
              variant={availability_variant(model["availability"])}
            >
              {model["availability"]}
            </.badge>
          </:col>

          <:col :let={model} label="Input">
            <span
              id={"model-input-rate-#{model["id"]}"}
              class="tabular-nums"
            >{rate(model, "input_per_million_tokens")}</span>
          </:col>

          <:col :let={model} label="Cached input">
            <span class="tabular-nums">{cached_rate(model)}</span>
          </:col>

          <:col :let={model} label="Output">
            <span
              id={"model-output-rate-#{model["id"]}"}
              class="tabular-nums"
            >{rate(model, "output_per_million_tokens")}</span>
          </:col>

          <:col :let={model} label="Basis">
            <.badge
              id={"model-basis-#{model["id"]}"}
              variant={basis_variant(model["pricing_basis"])}
              data-basis={model["pricing_basis"]}
            >
              {model["pricing_basis"]}
            </.badge>
            <p
              id={"model-pricing-id-#{model["id"]}"}
              class="mt-0.5 font-mono text-xs text-muted-foreground"
            >
              {get_in(model, ["pricing", "id"]) || "unpriced"}
            </p>
          </:col>

          <:col :let={model} label="Context">
            <span class="tabular-nums">{tokens(model["context_window"])}</span>
            <p class="mt-0.5 text-xs text-muted-foreground">
              {tokens(model["max_output"])} out
            </p>
          </:col>
        </.table>

        <p class="text-xs text-muted-foreground">
          Rates are US dollars per million tokens. Cached reads are charged at the cached
          rate where a lane declares one and at the input rate where it does not, because
          a lane that has not said otherwise has not offered a discount.
        </p>

        <section id="model-catalog-bases" class="space-y-2">
          <h2 class="text-sm font-semibold">What the basis means</h2>
          <.list>
            <:item title="declared">
              The operator entered the provider's published rates. This is the only basis
              anything may bill from.
            </:item>
            <:item title="provisional">
              Rates this deployment wrote to make itself run, or rates whose table it can
              no longer resolve. A figure, not a bill.
            </:item>
            <:item title="unpriced">
              No rates. Calls on this lane record no cost, and every surface that reads
              them shows the word rather than a zero.
            </:item>
          </.list>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp availability_variant("available"), do: :success
  defp availability_variant("degraded"), do: :warning
  defp availability_variant(_unavailable), do: :danger

  defp basis_variant("declared"), do: :success
  defp basis_variant("provisional"), do: :warning
  defp basis_variant(_unpriced), do: :dim

  # A lane with no rates gets the word, never a figure. `$0.00` here would be
  # the most confident wrong number on the page.
  defp rate(%{"pricing" => %{} = pricing}, key), do: dollars(Map.get(pricing, key))
  defp rate(_model, _key), do: "Unpriced"

  # A priced lane that declares no cached rate is not offering free cache
  # reads: `Pricing.price/2` charges them at the input rate, so that is what
  # this cell says.
  defp cached_rate(%{"pricing" => %{} = pricing}) do
    case Map.fetch(pricing, "cached_input_per_million_tokens") do
      {:ok, value} -> dollars(value)
      :error -> "at input rate"
    end
  end

  defp cached_rate(_model), do: "Unpriced"

  defp dollars(nil), do: "Unpriced"

  defp dollars(microusd) when is_integer(microusd) do
    "$" <> :erlang.float_to_binary(microusd / 1_000_000, decimals: 2)
  end

  defp tokens(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp tokens(_count), do: "—"
end
