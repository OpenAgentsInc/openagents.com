defmodule OpenAgents.DoNotBuildRegisterTest do
  use ExUnit.Case, async: false

  alias OpenAgents.DoNotBuildRegister

  defmodule AnalyticsSink do
    def capture(event, distinct_id, properties) do
      send(Application.fetch_env!(:openagents, :do_not_build_test_pid), {
        :captured,
        event,
        distinct_id,
        properties
      })
    end
  end

  setup do
    original_token = Application.get_env(:openagents, :posthog_project_token)
    original_sink = Application.get_env(:openagents, :analytics_sink)
    original_pid = Application.get_env(:openagents, :do_not_build_test_pid)

    Application.put_env(:openagents, :posthog_project_token, "phc_test")
    Application.put_env(:openagents, :analytics_sink, AnalyticsSink)
    Application.put_env(:openagents, :do_not_build_test_pid, self())

    on_exit(fn ->
      restore_env(:posthog_project_token, original_token)
      restore_env(:analytics_sink, original_sink)
      restore_env(:do_not_build_test_pid, original_pid)
    end)

    :ok
  end

  test "the committed register is valid, complete, and history preserving" do
    assert {:ok, register} = DoNotBuildRegister.load()
    assert length(register["entries"]) == 9

    assert register["entries"]
           |> Enum.map(& &1["current"]["state"])
           |> Enum.uniq()
           |> Enum.sort() == ~w(deferred rejected retired superseded)

    assert Enum.all?(register["entries"], fn entry ->
             List.last(entry["history"]) == entry["current"]
           end)

    [entry | rest] = register["entries"]

    invalid =
      put_in(register, ["entries"], [put_in(entry, ["current", "state"], "retired") | rest])

    assert {:error, :invalid_entry} = DoNotBuildRegister.validate(invalid)
  end

  test "matching uses explicit phrases rather than broad product keywords" do
    assert %{"id" => "DNB-003"} =
             DoNotBuildRegister.match("Replace npm with Bun in production")

    assert %{"id" => "DNB-008"} =
             DoNotBuildRegister.match(%{
               title: "Split Sarah into a Rust service",
               body: "Prepare the runtime boundary."
             })

    refute DoNotBuildRegister.match("Use Bun for a disposable local benchmark")
    refute DoNotBuildRegister.match("Improve the Spark wallet activity table")
    refute DoNotBuildRegister.match("Document optional Claude Code adapters")
  end

  test "FastFollow suppresses a match and records only bounded metadata" do
    proposal = "Add Copilot as an executor for delegated work"

    assert {:suppressed, %{"id" => "DNB-006"}} =
             DoNotBuildRegister.screen_fast_follow(proposal)

    assert_receive {:captured, "fast_follow_proposal_suppressed", "system_fast_follow",
                    properties}

    assert properties["register_id"] == "DNB-006"
    assert properties["decision_state"] == "deferred"
    assert String.length(properties["proposal_fingerprint"]) == 64
    refute inspect(properties) =~ proposal
  end

  test "new evidence and a decision record require review instead of bypassing the register" do
    proposal = "Build a hosted Spark wallet"

    assert {:suppressed, %{"id" => "DNB-001"}} =
             DoNotBuildRegister.screen_fast_follow(proposal, new_evidence: "custody changed")

    assert {:review_required, %{"id" => "DNB-001"}} =
             DoNotBuildRegister.screen_fast_follow(proposal,
               new_evidence: "A self-custodial implementation shipped.",
               decision_record: "docs/decisions/0010-spark-wallet.md"
             )

    assert :allow = DoNotBuildRegister.screen_fast_follow("Add project dependency labels")
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
