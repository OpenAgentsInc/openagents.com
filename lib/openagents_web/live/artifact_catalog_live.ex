defmodule OpenAgentsWeb.ArtifactCatalogLive do
  @moduledoc "Authenticated read-only catalog for verified traces and datasets."

  use OpenAgentsWeb, :live_view

  alias OpenAgents.ArtifactCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Artifact catalog · OpenAgents")
     |> assign(:form, to_form(%{"q" => "", "artifact_type" => ""}, as: :filters))
     |> assign(:listings, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "q" => Map.get(params, "q", ""),
      "artifact_type" => Map.get(params, "artifact_type", "")
    }

    {:noreply,
     socket
     |> assign(:form, to_form(filters, as: :filters))
     |> assign(:listings, ArtifactCatalog.list_public_listings(filters))}
  end

  @impl true
  def handle_event("search", %{"filters" => filters}, socket) do
    query =
      filters
      |> Map.take(["q", "artifact_type"])
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/artifact-catalog?#{query}")}
  end

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp size_text(bytes) when bytes < 1_000, do: "#{bytes} B"
  defp size_text(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} kB"
  defp size_text(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp digest(digest), do: "#{binary_part(digest, 0, 12)}…"

  defp price_text(price) when map_size(price) == 0, do: "Not priced"

  defp price_text(price) do
    amount = Map.get(price, "amount")
    currency = Map.get(price, "currency")
    unit = Map.get(price, "unit")

    [amount, currency, unit]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Artifact catalog"
      subtitle="Verified traces and datasets"
    >
      <section id="artifact-catalog" class="mx-auto w-full max-w-7xl space-y-6">
        <.header>
          Licensed artifacts
          <:subtitle>
            Discover compatible artifacts without exposing private source metadata.
          </:subtitle>
        </.header>

        <.card id="artifact-catalog-search" class="p-4">
          <.form
            for={@form}
            id="artifact-catalog-filter-form"
            phx-submit="search"
            class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_12rem_auto]"
          >
            <.input
              field={@form[:q]}
              type="search"
              label="Search"
              placeholder="Description, digest, or buyer"
            />
            <.input
              field={@form[:artifact_type]}
              type="select"
              label="Artifact type"
              prompt="All artifacts"
              options={[{"Dataset", "dataset"}, {"Trace", "trace"}]}
            />
            <.button id="artifact-catalog-search-button" type="submit" class="self-end">
              Search catalog
            </.button>
          </.form>
        </.card>

        <.empty
          :if={@listings == []}
          id="artifact-catalog-empty"
          title="No compatible artifacts"
        >
          Change the search terms or artifact type.
        </.empty>

        <div id="artifact-catalog-listings" class="grid gap-4 lg:grid-cols-2">
          <.card
            :for={listing <- @listings}
            id={"artifact-listing-#{listing.id}"}
            class="group flex h-full flex-col gap-5 p-5 transition hover:-translate-y-0.5 hover:shadow-lg"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="space-y-2">
                <div class="flex flex-wrap items-center gap-2">
                  <.badge variant={:info}>{listing.artifact_type}</.badge>
                  <.badge variant={:success}>licensed</.badge>
                </div>
                <h2 class="text-lg font-semibold text-foreground">
                  {listing.owner_description}
                </h2>
                <p class="text-sm text-muted-foreground">
                  Offered by {listing.owner_ref} for {listing.buyer_name}
                </p>
              </div>
              <p class="text-sm font-medium text-foreground">{price_text(listing.price)}</p>
            </div>

            <dl class="grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
              <div>
                <dt class="text-muted-foreground">Artifact digest</dt>
                <dd class="font-mono text-foreground" title={listing.artifact_digest}>
                  {digest(listing.artifact_digest)}
                </dd>
              </div>
              <div>
                <dt class="text-muted-foreground">Provenance digest</dt>
                <dd class="font-mono text-foreground" title={listing.provenance_digest}>
                  {digest(listing.provenance_digest)}
                </dd>
              </div>
              <div>
                <dt class="text-muted-foreground">Size</dt>
                <dd class="text-foreground">{size_text(listing.size_bytes)}</dd>
              </div>
              <div>
                <dt class="text-muted-foreground">Buyer class</dt>
                <dd class="text-foreground">{listing.buyer_class}</dd>
              </div>
              <div>
                <dt class="text-muted-foreground">Schema</dt>
                <dd class="text-foreground">
                  {Map.get(listing.schema, "name", "Documented")} {Map.get(
                    listing.schema,
                    "version",
                    ""
                  )}
                </dd>
              </div>
              <div>
                <dt class="text-muted-foreground">Evidence fresh at</dt>
                <dd class="text-foreground">{stamp(listing.evidence_fresh_at)}</dd>
              </div>
            </dl>

            <div class="mt-auto flex flex-wrap items-center justify-between gap-3 border-t border-border pt-4">
              <p class="text-xs text-muted-foreground">
                Verification: {Map.get(listing.verification_policy, "method", "policy bound")}
              </p>
              <.button
                id={"artifact-listing-export-#{listing.id}"}
                variant={:outline}
                size={:sm}
                href={~p"/api/artifact-listings/#{listing.id}/export"}
                download
              >
                Export listing
              </.button>
            </div>
          </.card>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
