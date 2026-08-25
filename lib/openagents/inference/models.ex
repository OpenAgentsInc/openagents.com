defmodule OpenAgents.Inference.Models do
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
  a client asks for and what the grant publishes — `ox-alpha`. The
  `provider_model` is what the provider is called with — `stealth/ox-alpha`.
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

  @type t :: %{
          id: String.t(),
          provider: atom(),
          adapter: module(),
          provider_model: String.t(),
          context_window: pos_integer(),
          max_output: pos_integer()
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
  The model with this id, or `:error`.

  A thread opened before this list existed carries the vendor string
  (`stealth/ox-alpha`) in its `model` column, so a vendor spelling resolves to
  the model it routes rather than leaving those threads unable to mint.
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

  @doc """
  The public projection of the catalog, for `GET /api/v1/models`.

  No adapter module and no credential state beyond the availability word: a
  client learns what it can select and what each selection can carry, nothing
  about how the server is wired.
  """
  @spec catalog() :: [map()]
  def catalog do
    default_id = default_id()

    Enum.map(all(), fn model ->
      %{
        "id" => model.id,
        "provider" => Atom.to_string(model.provider),
        "context_window" => model.context_window,
        "max_output" => model.max_output,
        "availability" => if(available?(model), do: "available", else: "unavailable"),
        "default" => model.id == default_id
      }
    end)
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
      max_output: entry.max_output
    }
  end

  defp value({:config, key}) when is_atom(key), do: Application.fetch_env!(:openagents, key)
  defp value(literal) when is_binary(literal), do: literal
end
