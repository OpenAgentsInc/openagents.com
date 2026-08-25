defmodule OpenAgents.Inference.HealthTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Inference.Health
  alias OpenAgents.Inference.Models

  setup do
    Health.reset()
    on_exit(&Health.reset/0)
    :ok
  end

  describe "what a lane has lately done" do
    test "a lane nothing has called is unknown, which is not a verdict either way" do
      assert Health.status("never-called") == {:unknown, nil}
    end

    test "a success makes a lane healthy" do
      Health.record_success("gpt-5.6-luna")
      assert Health.status("gpt-5.6-luna") == {:healthy, nil}
    end

    test "one failure is not yet degraded, but the upstream status is kept" do
      Health.record_failure("gemini-3.7-flash", 503)
      assert Health.status("gemini-3.7-flash") == {:healthy, 503}
    end

    test "consecutive failures degrade the lane and carry the last status" do
      for _ <- 1..Health.degraded_after(), do: Health.record_failure("gemini-3.7-flash", 429)
      assert Health.status("gemini-3.7-flash") == {:degraded, 429}
    end

    test "a success clears the failure run rather than decrementing it" do
      for _ <- 1..Health.degraded_after(), do: Health.record_failure("gemini-3.7-flash", 500)
      assert {:degraded, _} = Health.status("gemini-3.7-flash")

      Health.record_success("gemini-3.7-flash")
      assert Health.status("gemini-3.7-flash") == {:healthy, nil}
    end

    test "a failure with no upstream status reports none rather than inventing one" do
      for _ <- 1..Health.degraded_after(), do: Health.record_failure("ox-alpha", nil)
      assert Health.status("ox-alpha") == {:degraded, nil}
    end

    test "lanes are tracked apart" do
      for _ <- 1..Health.degraded_after(), do: Health.record_failure("gemini-3.7-flash", 502)
      Health.record_success("gpt-5.6-luna")

      assert {:degraded, 502} = Health.status("gemini-3.7-flash")
      assert {:healthy, nil} = Health.status("gpt-5.6-luna")
    end
  end

  describe "what the catalog publishes" do
    test "an untried lane still reads available, because silence is not failure" do
      entry = Enum.find(Models.catalog(), &(&1["id"] == "gemini-3.7-flash"))
      assert entry["availability"] == "available"
    end

    test "a lane whose calls keep failing stops claiming it is available" do
      for _ <- 1..Health.degraded_after(), do: Health.record_failure("gemini-3.7-flash", 503)

      entry = Enum.find(Models.catalog(), &(&1["id"] == "gemini-3.7-flash"))
      assert entry["availability"] == "degraded"

      # The lanes that are answering are unaffected, so a client can still pick
      # one that works — the whole point of publishing this.
      others = Enum.reject(Models.catalog(), &(&1["id"] == "gemini-3.7-flash"))
      assert Enum.all?(others, &(&1["availability"] in ["available", "unavailable"]))
    end

    test "a recovered lane goes back to available" do
      for _ <- 1..Health.degraded_after(), do: Health.record_failure("gemini-3.7-flash", 503)
      Health.record_success("gemini-3.7-flash")

      entry = Enum.find(Models.catalog(), &(&1["id"] == "gemini-3.7-flash"))
      assert entry["availability"] == "available"
    end
  end
end
