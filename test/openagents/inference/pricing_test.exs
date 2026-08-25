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
      assert Pricing.pricing_id_for("gemini-3.7-flash") == "placeholder.gemini-3.7-flash.v1"
    end

    test "rates without a table name are unattributed rather than silently accepted" do
      assert Pricing.pricing_id(%{input_per_million_tokens: 1}) == "unattributed"
    end

    test "a model outside the catalog is unpriced rather than assumed free" do
      assert Pricing.pricing_id_for("not-a-model-this-deployment-serves") == "unpriced"
      assert Pricing.basis("not-a-model-this-deployment-serves") == "unpriced"
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

      assert priced["estimated_cost_microusd"] == 1_250_000
      assert priced["pricing_id"] == "placeholder.gemini-3.7-flash.v1"
      assert Pricing.cost(priced) == 1_250_000
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

      # 600k uncached input + 100k cache write at $1.25/M, 400k cached read at
      # $0.10/M: 700_000 * 1.25 + 400_000 * 0.10, in microUSD.
      assert priced["estimated_cost_microusd"] == 875_000 + 40_000
    end
  end

  describe "reading a stored record back" do
    test "a placeholder-priced record carries a cost but is not billable" do
      priced = Pricing.price(%{"input_tokens" => 1_000_000}, "gemini-3.7-flash")

      assert Pricing.priced?(priced)
      assert Pricing.usage_basis(priced) == "provisional"
      refute Pricing.billable?(priced)
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
    test "no lane claims declared rates, because none has been given any" do
      # The moment an operator enters real rates and sets `source: :declared`,
      # this test fails and whoever did it has to say so here. That is the
      # point: turning a lane billable is a decision, not a config typo.
      bases = Enum.map(OpenAgents.Inference.Models.catalog(), & &1["pricing_basis"])

      assert "declared" not in bases
      assert "unpriced" in bases
      assert "provisional" in bases
    end

    test "the unpriced lane publishes no pricing block, and says so in one word" do
      luna =
        OpenAgents.Inference.Models.catalog()
        |> Enum.find(&(&1["id"] == unpriced_model_id()))

      refute Map.has_key?(luna, "pricing")
      assert luna["pricing_basis"] == "unpriced"
    end

    test "a priced lane publishes its table and its basis beside the rates" do
      gemini =
        OpenAgents.Inference.Models.catalog()
        |> Enum.find(&(&1["id"] == "gemini-3.7-flash"))

      assert gemini["pricing"]["id"] == "placeholder.gemini-3.7-flash.v1"
      assert gemini["pricing"]["basis"] == "provisional"
      assert gemini["pricing_basis"] == "provisional"
    end
  end
end
