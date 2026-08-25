defmodule OpenAgents.Inference.Pricing do
  @moduledoc """
  What a metered call cost, and on whose authority.

  Metering that prices some lanes at zero is worse than no metering: it reports
  a number, and the number is wrong. `gpt-5.6-luna` is the lane the coder
  actually runs on and this deployment has never been told its rates, so a
  surface that read a missing cost as zero would have shown `$0.00` beside a
  session that spent real money — and shown it in the same typeface as a figure
  that was measured.

  So a cost is never a bare integer here. Every metered usage record carries a
  `pricing_id` naming the rate table it was priced against, and the id resolves
  to one of three bases:

    * `declared` — the operator entered the provider's published rates. This is
      the only basis anything may bill from (`billable?/1`).
    * `provisional` — the deployment carries rates that were written to make
      the system run rather than read off a provider's price page, or rates
      whose table is unnamed. A cost is computed and labelled; no bill may
      derive from it.
    * `unpriced` — no rates at all. No `estimated_cost_microusd` is written,
      `cost/1` answers `nil`, and every reader shows the word rather than a
      zero.

  `unpriced` is not an error state and it is not a free lane. It is the
  deployment saying it does not know what a call cost, which is a different
  fact from the call having cost nothing, and the distinction survives all the
  way to the read surfaces. Turning it into a number is an owner action —
  entering real rates in `config :openagents, :model_catalog` — not something
  this module may guess at.

  The `pricing_id` convention is `OpenAgents.Voice.Usage`'s, so
  `OpenAgents.DataRights.AtifExport` reads inference usage and voice usage with
  the same rule. The one difference is deliberate: voice writes a zero cost
  beside `pricing_id: "unpriced"`, and inference writes no cost key at all.
  """

  alias OpenAgents.Inference.Models

  @unpriced "unpriced"
  @unattributed "unattributed"

  @doc "The `pricing_id` written for a lane with no declared rates."
  @spec unpriced() :: String.t()
  def unpriced, do: @unpriced

  @doc """
  The basis of a catalog pricing map: `declared`, `provisional`, or `unpriced`.

  A pricing map that does not say where its rates came from is `provisional`,
  not `declared`. Failing closed is the point: a rate somebody added without
  recording its source is exactly the rate nothing should bill from.
  """
  @spec basis_of(map() | nil) :: String.t()
  def basis_of(nil), do: @unpriced
  def basis_of(%{source: :declared}), do: "declared"
  def basis_of(%{}), do: "provisional"

  @doc "The basis for a model, by catalog id or resolved model."
  @spec basis(map() | String.t() | nil) :: String.t()
  def basis(%{pricing: pricing}), do: basis_of(pricing)

  def basis(model_id) do
    case Models.fetch(model_id) do
      {:ok, model} -> basis_of(model.pricing)
      :error -> @unpriced
    end
  end

  @doc """
  The id of the rate table a model is priced against.

  `unpriced` where the catalog declares no rates, `unattributed` where it
  declares rates without naming their table.
  """
  @spec pricing_id(map() | nil) :: String.t()
  def pricing_id(nil), do: @unpriced
  def pricing_id(%{} = pricing), do: Map.get(pricing, :id) || @unattributed

  @doc "The id of the rate table this model is priced against, by catalog id."
  @spec pricing_id_for(String.t() | nil) :: String.t()
  def pricing_id_for(model_id) do
    case Models.fetch(model_id) do
      {:ok, model} -> pricing_id(model.pricing)
      :error -> @unpriced
    end
  end

  @doc """
  Price a merged usage map against a model's declared rates.

  Always stamps `pricing_id`, so the stored record says on whose authority it
  was priced — or that it was not priced at all. `estimated_cost_microusd` is
  written only where rates exist, because a zero there would be read as a
  measurement.

  Cached read tokens are split out of the input and charged at the cached rate
  where the model declares one. Cache write tokens are charged as regular
  input, because writing a cache is not reading one.
  """
  @spec price(map(), String.t() | nil) :: map()
  def price(usage, model_id) when is_map(usage) do
    pricing =
      case Models.fetch(model_id) do
        {:ok, model} -> model.pricing
        :error -> nil
      end

    usage
    |> Map.put("pricing_id", pricing_id(pricing))
    |> put_cost(pricing)
  end

  defp put_cost(
         usage,
         %{input_per_million_tokens: input_rate, output_per_million_tokens: out_rate} = pricing
       ) do
    input = integer(usage["input_tokens"])
    output = integer(usage["output_tokens"])
    cache_read = integer(usage["cache_read_input_tokens"])
    cache_write = integer(usage["cache_write_input_tokens"])
    cached_rate = Map.get(pricing, :cached_input_per_million_tokens, input_rate)

    uncached = max(0, input - cache_read) + cache_write
    cost = uncached * input_rate + cache_read * cached_rate + output * out_rate

    Map.put(usage, "estimated_cost_microusd", div(cost, 1_000_000))
  end

  defp put_cost(usage, _no_rates), do: usage

  @doc """
  What a stored usage record cost, or `nil` where the deployment does not know.

  `nil` is the whole point of this function. Callers that need a number must
  decide what to do without one instead of being handed a zero that reads like
  a measurement.
  """
  @spec cost(map() | nil) :: integer() | nil
  def cost(%{} = usage) do
    case Map.get(usage, "estimated_cost_microusd") do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _absent -> nil
    end
  end

  def cost(_usage), do: nil

  @doc """
  The basis of a stored usage record.

  A record written before `pricing_id` existed carries a cost and no table
  name. That is `provisional` — a figure whose rates cannot be dereferenced is
  precisely a figure nothing may bill from — and a record with neither is
  `unpriced`.
  """
  @spec usage_basis(map() | nil) :: String.t()
  def usage_basis(%{} = usage) do
    case Map.get(usage, "pricing_id") do
      @unpriced -> @unpriced
      id when is_binary(id) -> basis_of_id(id, usage)
      _absent -> if is_nil(cost(usage)), do: @unpriced, else: "provisional"
    end
  end

  def usage_basis(_usage), do: @unpriced

  defp basis_of_id(id, usage) do
    cond do
      is_nil(cost(usage)) -> @unpriced
      declared_id?(id) -> "declared"
      true -> "provisional"
    end
  end

  # A stored record names its table, and whether that table was declared is a
  # property of the catalog rather than of the string. A table that has since
  # been removed from the catalog is read as provisional: it was priced against
  # something this deployment can no longer dereference, and NO BILL WITHOUT A
  # DEREFERENCEABLE USAGE RECORD is the contract.
  defp declared_id?(id) do
    Enum.any?(Models.all(), fn model ->
      pricing_id(model.pricing) == id and basis_of(model.pricing) == "declared"
    end)
  end

  @doc """
  Whether a stored usage record may be billed from.

  Only a `declared` basis qualifies. A provisional cost is a working figure and
  an unpriced call is an unknown; billing from either is the failure this
  module exists to prevent.
  """
  @spec billable?(map() | nil) :: boolean()
  def billable?(usage), do: usage_basis(usage) == "declared"

  @doc "Whether this record carries a cost at all."
  @spec priced?(map() | nil) :: boolean()
  def priced?(usage), do: not is_nil(cost(usage))

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)
  defp integer(_value), do: 0
end
