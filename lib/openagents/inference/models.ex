defmodule OpenAgents.Inference.Models do
  alias OpenAgents.Inference.Health
  alias OpenAgents.Inference.Pricing

  @moduledoc """
  The typed model catalog: every model this deployment serves, and the
  provider lane that serves each.

  A grant carries one model and the proxy pins it, so the set of models a
  caller may be granted is the set the proxy can route. This module reads that
  set from one config-driven list, `config :openagents, :model_catalog`:
  `OpenAgents.Threads` admits a thread's model against it, `OpenAgents.Inference.mint/1`
  refuses a grant naming anything else, `OpenAgentsWeb.InferenceProxyController`
  asks it which adapter to call, and `GET /api/v1/models` publishes it so a
  client selects from what is actually served instead of guessing.

  Two names appear per model and they are not the same name. The `id` is what
  a client asks for and what the grant publishes — `glm-5.3-flash`. The
  `provider_model` is what the provider is called with — `zai/glm-5.3-flash`.
  Keeping them apart is what lets the routed vendor string change without
  invalidating grants that already name the model. A catalog entry may write
  either name as `{:config, key}` to follow a runtime-configurable value.

  A catalog entry names a provider lane, not a module: the adapter module for
  each lane is read from configuration (`@provider_lanes`), so
  `config/test.exs` substitutes `OpenAgents.Providers.Test` and no test
  reaches a vendor. Adding a provider is one lane here, one adapter module,
  and one credential in runtime configuration — no catalog entry carries a
  secret.

  Availability is the adapter's own report: an adapter that exports
  `configured?/0` is asked whether its credential is configured, and a lane
  whose credential is absent is **listed as unavailable rather than omitted**,
  so a client can tell "not served here" from "served here, not currently
  configured". An unavailable model is refused at thread admission and at the
  proxy (`model_unavailable`), never silently substituted (PROVIDER-002).
  """

  # Lane name → the application-config key that holds the lane's adapter
  # module. Modules stay out of `:model_catalog` so the catalog is pure data
  # and the test environment swaps adapters without touching it.
  @provider_lanes %{
    openai: :provider,
    openrouter: :openrouter_provider,
    vercel_gateway: :vercel_gateway_provider
  }

  @type pricing :: %{
          required(:input_per_million_tokens) => non_neg_integer(),
          required(:output_per_million_tokens) => non_neg_integer(),
          optional(:cached_input_per_million_tokens) => non_neg_integer()
        }

  @type t :: %{
          id: String.t(),
          provider: atom(),
          adapter: module(),
          provider_model: String.t(),
          context_window: pos_integer(),
          max_output: pos_integer(),
          pricing: pricing() | nil
        }

  @doc "Every model in the catalog, in the order a client should offer them."
  @spec all() :: [t()]
  def all do
    :openagents
    |> Application.fetch_env!(:model_catalog)
    |> Enum.map(&resolve/1)
    |> Enum.uniq_by(& &1.id)
  end

  @doc "The model ids a grant may pin."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(all(), & &1.id)

  @doc "The model a grant pins when its caller names none: the catalog's first entry."
  @spec default() :: t()
  def default, do: hd(all())

  @doc "The id of the model a grant pins when its caller names none."
  @spec default_id() :: String.t()
  def default_id, do: default().id

  @doc """
  The model the server selects for a caller that names none, by policy.

  A lane that is configured and not degraded is preferred, in catalog order.
  If no such lane exists because every configured lane is degraded, or
  because no lane is configured, the catalog default is returned. The proxy
  still uses `Models.available?/1` to refuse the call when the default is
  unavailable, so a degraded default is used but an unavailable one is not.
  """
  @spec select() :: t()
  def select do
    models = all()

    case Enum.find(models, &healthy?/1) do
      nil -> default()
      model -> model
    end
  end

  @doc "The id of the model `select/0` returns."
  @spec select_id() :: String.t()
  def select_id, do: select().id

  @doc """
  The model with this id, or `:error`.

  A thread opened before this list existed carries a vendor string rather than
  a public id in its `model` column, so a vendor spelling (`zai/glm-5.3-flash`)
  resolves to the model it routes rather than leaving those threads unable to
  mint. A vendor string this catalog no longer routes does not resolve: a
  withdrawn model is withdrawn, not quietly replaced with a survivor.
  """
  @spec fetch(String.t() | nil) :: {:ok, t()} | :error
  def fetch(id) when is_binary(id) do
    models = all()

    case Enum.find(models, &(&1.id == id)) || Enum.find(models, &(&1.provider_model == id)) do
      nil -> :error
      model -> {:ok, model}
    end
  end

  def fetch(_id), do: :error

  @doc """
  What a client should believe about a lane, as one word.

  `unavailable` means the deployment cannot call it at all — no credential.
  `degraded` means it is configured and its recent calls have failed, which is
  the case the old two-word answer could not express: a lane whose wiring is
  right and whose every call fails used to publish `available` and mislead the
  caller that trusted it (#238).

  A lane nothing has called since boot is `available`, not `degraded`. Silence
  is not evidence of failure, and refusing to offer an untried lane would make
  every restart look like an outage.
  """
  @spec availability(t()) :: String.t()
  def availability(%{id: id} = model) do
    cond do
      not available?(model) -> "unavailable"
      match?({:degraded, _}, Health.status(id)) -> "degraded"
      true -> "available"
    end
  end

  @doc """
  Whether this model's adapter reports its credential configured.

  An adapter that does not export `configured?/0` is taken as configured: the
  test adapters need no credential, and an adapter that cannot say is refused
  at call time by its own `missing_api_key` rather than guessed at here.
  """
  @spec available?(t()) :: boolean()
  def available?(%{adapter: adapter}) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :configured?, 0) do
      adapter.configured?()
    else
      true
    end
  end

  defp healthy?(%{id: id} = model) do
    available?(model) and not match?({:degraded, _}, Health.status(id))
  end

  @doc """
  The public projection of the catalog, for `GET /api/v1/models`.

  No adapter module and no credential state beyond the availability word: a
  client learns what it can select and what each selection can carry, nothing
  about how the server is wired. Pricing is exposed only when the deployment
  has declared rates for a model; an unpriced model has no `pricing` key so it
  is not read as zero before spend.

  Absence is a weak signal, though — a client that forgets to check for the key
  reads a missing price as no price rather than as an unknown one. So every
  entry also carries `pricing_basis`, one word alongside `availability`:
  `declared` where the operator entered the provider's published rates,
  `provisional` where the rates are a working figure nothing may bill from, and
  `unpriced` where there are none. A caller can read what a lane will cost, and
  whether that figure can be trusted, before it spends anything (METER-001).
  """
  @spec catalog() :: [map()]
  def catalog do
    default_id = default_id()

    Enum.map(all(), fn model ->
      pricing = Pricing.effective_pricing(model)

      base = %{
        "id" => model.id,
        "provider" => Atom.to_string(model.provider),
        "context_window" => model.context_window,
        "max_output" => model.max_output,
        "availability" => availability(model),
        "pricing_basis" => Pricing.basis_of(pricing),
        "default" => model.id == default_id
      }

      base
      |> maybe_put_pricing(pricing)
      |> maybe_put_promotion(model, pricing)
    end)
  end

  defp maybe_put_pricing(base, nil), do: base
  defp maybe_put_pricing(base, pricing), do: Map.put(base, "pricing", public_pricing(pricing))

  defp maybe_put_promotion(base, model, pricing) do
    case Pricing.promotion_ends_at(model) do
      %DateTime{} = ends_at ->
        Map.put(base, "pricing_promotion", %{
          "active" => Pricing.pricing_id(pricing) != Pricing.pricing_id(model.pricing),
          "ends_at" => DateTime.to_iso8601(ends_at)
        })

      nil ->
        base
    end
  end

  defp public_pricing(pricing) do
    base = %{
      "id" => Pricing.pricing_id(pricing),
      "basis" => Pricing.basis_of(pricing),
      "input_per_million_tokens" => pricing.input_per_million_tokens,
      "output_per_million_tokens" => pricing.output_per_million_tokens
    }

    case Map.fetch(pricing, :cached_input_per_million_tokens) do
      {:ok, value} -> Map.put(base, "cached_input_per_million_tokens", value)
      :error -> base
    end
  end

  @doc "The ids currently available to serve, for a refusal that names what is."
  @spec available_ids() :: [String.t()]
  def available_ids do
    all() |> Enum.filter(&available?/1) |> Enum.map(& &1.id)
  end

  defp resolve(entry) do
    %{
      id: value(entry.id),
      provider: entry.provider,
      adapter: Application.fetch_env!(:openagents, Map.fetch!(@provider_lanes, entry.provider)),
      provider_model: value(entry.provider_model),
      context_window: entry.context_window,
      max_output: entry.max_output,
      pricing: Map.get(entry, :pricing)
    }
  end

  defp value({:config, key}) when is_atom(key), do: Application.fetch_env!(:openagents, key)
  defp value(literal) when is_binary(literal), do: literal
end
