defmodule OpenAgents.Inference.PricingTest do
  @moduledoc """
  The rule that a cost is reported only where a price exists (METER-001).

  The failure this guards against is not a crash. It is a number: a lane with
  no declared rates summing to `$0.00` on a surface that looks like a bill,
  in the same typeface as a figure somebody measured. `gpt-5.6-luna` is that
  lane and it is the one the coder runs on, so every assertion below about
  "unpriced" is an assertion about the deployment's largest real spend.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Inference.Pricing

  # A name the catalog does not route. `gpt-5.6-luna` was an admitted lane with
  # no rates until it was withdrawn; now it is unpriced for the stronger reason
  # that it is not served at all, and either way it is what `unpriced` looks
  # like from the outside.
  defp unpriced_model_id, do: Application.fetch_env!(:openagents, :openai_model)

  describe "the basis of a catalog pricing map" do
    test "no pricing map at all is unpriced" do
      assert Pricing.basis_of(nil) == "unpriced"
    end

    test "rates that name the provider as their source are declared" do
      assert Pricing.basis_of(%{source: :declared, input_per_million_tokens: 1}) == "declared"
    end

    test "rates that do not say where they came from are provisional, not declared" do
      assert Pricing.basis_of(%{input_per_million_tokens: 1}) == "provisional"

      assert Pricing.basis_of(%{source: :placeholder, input_per_million_tokens: 1}) ==
               "provisional"
    end
  end

  describe "the id of the rate table" do
    test "a lane with no rates is priced against the unpriced table" do
      assert Pricing.pricing_id(nil) == "unpriced"
      assert Pricing.pricing_id_for(unpriced_model_id()) == "unpriced"
    end

    test "a lane with rates publishes the table those rates came from" do
      assert Pricing.pricing_id_for("gemini-3.7-flash") ==
               "declared.gemini-3.7-flash.intro-through-2026-12-31.v1"
    end

    test "rates without a table name are unattributed rather than silently accepted" do
      assert Pricing.pricing_id(%{input_per_million_tokens: 1}) == "unattributed"
    end

    test "a model outside the catalog is unpriced rather than assumed free" do
      assert Pricing.pricing_id_for("not-a-model-this-deployment-serves") == "unpriced"
      assert Pricing.basis("not-a-model-this-deployment-serves") == "unpriced"
    end
  end

  describe "the GLM free promotion" do
    test "uses zero declared rates before the cutoff and regular rates at the cutoff" do
      {:ok, glm} = OpenAgents.Inference.Models.fetch("glm-5.3-flash")

      promotional = Pricing.effective_pricing(glm, ~U[2026-08-31 23:59:59.999999Z])
      regular = Pricing.effective_pricing(glm, ~U[2026-09-01 00:00:00Z])

      assert promotional.id == "declared.glm-5.3-flash.free-through-2026-08-31.v1"
      assert promotional.source == :declared
      assert promotional.input_per_million_tokens == 0
      assert promotional.output_per_million_tokens == 0
      assert promotional.cached_input_per_million_tokens == 0
      assert Pricing.promotion_active?(glm, ~U[2026-08-31 23:59:59Z])

      assert regular.id == "declared.glm-5.3-flash.v1"
      assert regular.source == :declared
      assert regular.input_per_million_tokens == 150_000
      refute Pricing.promotion_active?(glm, ~U[2026-09-01 00:00:00Z])
      assert Pricing.promotion_ends_at(glm) == ~U[2026-09-01 00:00:00Z]
    end

    test "the declared promotion remains billable as a zero-cost historical record" do
      usage = %{
        "pricing_id" => "declared.glm-5.3-flash.free-through-2026-08-31.v1",
        "estimated_cost_microusd" => 0
      }

      assert Pricing.usage_basis(usage) == "declared"
      assert Pricing.billable?(usage)
    end
  end

  describe "the Gemini 3.7 Flash published rates" do
    test "uses intro rates before the cutoff and list rates at the cutoff" do
      {:ok, gemini} = OpenAgents.Inference.Models.fetch("gemini-3.7-flash")

      introductory = Pricing.effective_pricing(gemini, ~U[2026-12-31 23:59:59.999999Z])
      list = Pricing.effective_pricing(gemini, ~U[2027-01-01 00:00:00Z])

      assert introductory.id == "declared.gemini-3.7-flash.intro-through-2026-12-31.v1"
      assert introductory.source == :declared
      assert introductory.input_per_million_tokens == 750_000
      assert introductory.output_per_million_tokens == 3_750_000
      assert introductory.cached_input_per_million_tokens == 75_000
      assert Pricing.promotion_active?(gemini, ~U[2026-12-31 23:59:59Z])

      assert list.id == "declared.gemini-3.7-flash.v1"
      assert list.source == :declared
      assert list.input_per_million_tokens == 1_500_000
      assert list.output_per_million_tokens == 7_500_000
      assert list.cached_input_per_million_tokens == 150_000
      refute Pricing.promotion_active?(gemini, ~U[2027-01-01 00:00:00Z])
      assert Pricing.promotion_ends_at(gemini) == ~U[2027-01-01 00:00:00Z]
    end
  end

  describe "pricing one usage record" do
    test "an unpriced model writes no cost key — not a zero" do
      priced =
        Pricing.price(%{"input_tokens" => 4_000, "output_tokens" => 900}, unpriced_model_id())

      refute Map.has_key?(priced, "estimated_cost_microusd")
      assert priced["pricing_id"] == "unpriced"
      assert Pricing.cost(priced) == nil
      assert Pricing.usage_basis(priced) == "unpriced"
      refute Pricing.priced?(priced)
    end

    test "a priced model writes the cost and names the table it was priced against" do
      priced =
        Pricing.price(%{"input_tokens" => 1_000_000, "output_tokens" => 0}, "gemini-3.7-flash")

      # Test `pricing_now` is 2026-09-01, inside the introductory promotion.
      assert priced["estimated_cost_microusd"] == 750_000
      assert priced["pricing_id"] == "declared.gemini-3.7-flash.intro-through-2026-12-31.v1"
      assert Pricing.cost(priced) == 750_000
    end

    test "cached reads are charged at the cached rate and cache writes at the input rate" do
      priced =
        Pricing.price(
          %{
            "input_tokens" => 1_000_000,
            "cache_read_input_tokens" => 400_000,
            "cache_write_input_tokens" => 100_000,
            "output_tokens" => 0
          },
          "gemini-3.7-flash"
        )

      # 600k uncached input + 100k cache write at $0.75/M, 400k cached read at
      # $0.075/M: 700_000 * 0.75 + 400_000 * 0.075, in microUSD.
      assert priced["estimated_cost_microusd"] == 525_000 + 30_000
    end
  end

  describe "reading a stored record back" do
    test "a declared Gemini record carries a cost and is billable" do
      priced = Pricing.price(%{"input_tokens" => 1_000_000}, "gemini-3.7-flash")

      assert Pricing.priced?(priced)
      assert Pricing.usage_basis(priced) == "declared"
      assert Pricing.billable?(priced)
    end

    test "an unpriced record is never billable" do
      priced = Pricing.price(%{"input_tokens" => 1_000_000}, unpriced_model_id())
      refute Pricing.billable?(priced)
    end

    test "a record written before pricing ids existed is provisional, not declared" do
      legacy = %{"input_tokens" => 10, "estimated_cost_microusd" => 42}

      assert Pricing.cost(legacy) == 42
      assert Pricing.usage_basis(legacy) == "provisional"
      refute Pricing.billable?(legacy)
    end

    test "a record naming a table this deployment no longer carries is not billable" do
      retired = %{
        "pricing_id" => "declared.some-retired-table.v1",
        "estimated_cost_microusd" => 9
      }

      assert Pricing.usage_basis(retired) == "provisional"
      refute Pricing.billable?(retired)
    end

    test "an empty or absent record is unpriced rather than zero" do
      assert Pricing.cost(%{}) == nil
      assert Pricing.cost(nil) == nil
      assert Pricing.usage_basis(%{}) == "unpriced"
      assert Pricing.usage_basis(nil) == "unpriced"
    end
  end

  describe "the catalog this deployment actually ships" do
    test "declared tables publish the configured rates" do
      bases = Enum.map(OpenAgents.Inference.Models.catalog(), & &1["pricing_basis"])

      free_router =
        Enum.find(OpenAgents.Inference.Models.catalog(), &(&1["id"] == "openrouter/free"))

      glm = Enum.find(OpenAgents.Inference.Models.catalog(), &(&1["id"] == "glm-5.3-flash"))

      assert Enum.all?(bases, &(&1 == "declared"))
      assert free_router["pricing"]["input_per_million_tokens"] == 0
      assert free_router["pricing"]["output_per_million_tokens"] == 0
      assert glm["pricing"]["input_per_million_tokens"] == 150_000
      assert glm["pricing"]["output_per_million_tokens"] == 500_000
    end

    test "every shipped lane carries rates, so none reads as unpriced" do
      bases = Enum.map(OpenAgents.Inference.Models.catalog(), & &1["pricing_basis"])

      assert "unpriced" not in bases
      assert Pricing.basis(unpriced_model_id()) == "unpriced"
    end

    test "a priced lane publishes its table and its basis beside the rates" do
      gemini =
        OpenAgents.Inference.Models.catalog()
        |> Enum.find(&(&1["id"] == "gemini-3.7-flash"))

      assert gemini["pricing"]["id"] == "declared.gemini-3.7-flash.intro-through-2026-12-31.v1"
      assert gemini["pricing"]["basis"] == "declared"
      assert gemini["pricing_basis"] == "declared"
    end
  end
end
