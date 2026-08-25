defmodule OpenAgents.Delegations.TargetTest do
  @moduledoc """
  The seam is only worth having if it is total.

  These tests derive their inputs from the substrate schemas rather than
  listing them, so a new Box state, run state, or work-job status fails here
  the day it lands instead of silently reading as `failed` on five surfaces.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Box.Run
  alias OpenAgents.Delegations.Target
  alias OpenAgents.Machines.Machine
  alias OpenAgents.Work.Job

  describe "the lifecycle vocabulary" do
    test "target lifecycles are the openagents.cloud_computer.v1 state enum" do
      assert Target.lifecycles() == ~w(cold queued starting active stopping failed destroyed)
    end

    test "every declared Box state maps into the vocabulary" do
      for state <- ConversationBox.states() do
        assert Target.box_lifecycle(state) in Target.lifecycles(),
               "Box state #{state} has no lifecycle"
      end
    end

    test "a fan-out item that admission has not admitted reads as queued" do
      assert Target.box_lifecycle("queued") == "queued"
    end

    test "no declared Box state silently reads as failed" do
      # `error` is the one Box state that means failure. If another state
      # starts reading as `failed`, it fell through the catch-all.
      failed = Enum.filter(ConversationBox.states(), &(Target.box_lifecycle(&1) == "failed"))
      assert failed == ["error"]
    end

    test "a Box is only startable once it is ready, idle, or already running" do
      active = Enum.filter(ConversationBox.states(), &(Target.box_lifecycle(&1) == "active"))
      assert Enum.sort(active) == ~w(idle ready running)
    end

    test "every declared Box run state maps into the delegation vocabulary" do
      for state <- Run.states() do
        assert Target.run_lifecycle(state) in Target.delegation_lifecycles(),
               "Box run state #{state} has no lifecycle"
      end
    end

    test "every declared work job status maps into the delegation vocabulary" do
      for status <- Job.statuses() do
        assert Target.job_lifecycle(status) in Target.delegation_lifecycles(),
               "work job status #{status} has no lifecycle"
      end
    end

    test "a lost or timed-out run and an interrupted or exhausted job all read as failed" do
      assert Target.run_lifecycle("lost") == "failed"
      assert Target.run_lifecycle("timed_out") == "failed"
      assert Target.job_lifecycle("interrupted") == "failed"
      assert Target.job_lifecycle("budget_exhausted") == "failed"
    end

    test "a terminal run and a terminal job agree on the word" do
      for state <- Run.terminal_states(), state != "lost" do
        refute Target.run_lifecycle(state) in ~w(queued starting active),
               "terminal run state #{state} still reads as live"
      end
    end
  end

  describe "a Computer's lifecycle" do
    test "an active, reachable computer is active" do
      assert Target.computer_lifecycle(machine(), true) == "active"
    end

    test "an active but unreachable computer is cold, never failed" do
      assert Target.computer_lifecycle(machine(), false) == "cold"
    end

    test "a revoked computer is destroyed even while a socket is still up" do
      revoked = %Machine{machine() | status: "revoked", revoked_at: DateTime.utc_now()}

      assert Target.computer_lifecycle(revoked, true) == "destroyed"
    end

    test "a revocation stamp alone is enough to read as destroyed" do
      stamped = %Machine{machine() | revoked_at: DateTime.utc_now()}

      assert Target.computer_lifecycle(stamped, true) == "destroyed"
    end
  end

  describe "custody" do
    test "is derived from the target kind and nothing else" do
      assert Target.custody("box") == "openagents_managed"
      assert Target.custody("computer") == "customer_premises"
    end

    test "covers every kind, and every value is admitted" do
      for kind <- Target.kinds() do
        assert Target.custody(kind) in Target.custodies()
      end
    end

    test "does not change with the lifecycle or the caller's authority" do
      for lifecycle <- Target.lifecycles(), authorized? <- [true, false] do
        assert Target.seam("box", lifecycle, authorized?)["custody"] == "openagents_managed"
        assert Target.seam("computer", lifecycle, authorized?)["custody"] == "customer_premises"
      end
    end
  end

  describe "runtime class" do
    test "a paired computer is the connected class the capacity catalog admits" do
      assert Target.runtime_class("computer") == "connected"
      assert OpenAgents.Capacity.Catalog.get("connected")["isolation"] == "customer_controlled"
    end

    test "a Box claims no class until its egress posture is established" do
      assert Target.runtime_class("box") == nil
    end
  end

  describe "capabilities" do
    test "an active target the caller can reach may be started" do
      assert Target.seam("box", "active", true)["capabilities"] == ["start"]
      assert Target.seam("computer", "active", true)["capabilities"] == ["start"]
    end

    test "no other lifecycle offers any capability" do
      for kind <- Target.kinds(), lifecycle <- Target.lifecycles(), lifecycle != "active" do
        assert Target.seam(kind, lifecycle, true)["capabilities"] == [],
               "#{kind} in #{lifecycle} advertised a capability"
      end
    end

    test "an unauthorized caller is offered nothing, whatever the lifecycle" do
      for kind <- Target.kinds(), lifecycle <- Target.lifecycles() do
        seam = Target.seam(kind, lifecycle, false)

        assert seam["capabilities"] == [], "#{kind} in #{lifecycle} leaked a capability"
      end
    end

    test "authority is refused by name, so it is not confused with a cold target" do
      assert Target.seam("computer", "active", false)["unavailable_reason"] == "not_authorized"
      assert Target.seam("computer", "cold", true)["unavailable_reason"] == "cold"
    end

    test "a reachable, authorized target gives no reason, because there is none" do
      assert Target.seam("box", "active", true)["unavailable_reason"] == nil
    end

    test "the reason for refusing is always the lifecycle itself" do
      for kind <- Target.kinds(), lifecycle <- Target.lifecycles(), lifecycle != "active" do
        assert Target.seam(kind, lifecycle, true)["unavailable_reason"] == lifecycle
      end
    end
  end

  describe "delegation capabilities" do
    test "a live delegation can be cancelled" do
      for lifecycle <- ~w(queued starting active) do
        assert Target.delegation_seam(lifecycle)["capabilities"] == ["cancel"]
      end
    end

    test "a finished delegation cannot" do
      for lifecycle <- ~w(succeeded failed cancelled) do
        assert Target.delegation_seam(lifecycle)["capabilities"] == []
      end
    end

    test "every delegation lifecycle is covered" do
      for lifecycle <- Target.delegation_lifecycles() do
        assert is_list(Target.delegation_seam(lifecycle)["capabilities"])
      end
    end

    test "every terminal work job status yields an uncancellable delegation" do
      for status <- ~w(completed failed cancelled interrupted budget_exhausted) do
        seam = status |> Target.job_lifecycle() |> Target.delegation_seam()

        assert seam["capabilities"] == [], "#{status} still offered cancel"
      end
    end
  end

  describe "the seam document" do
    test "carries the same fields for every kind and lifecycle" do
      expected = ~w(capabilities custody lifecycle runtime_class unavailable_reason)

      for kind <- Target.kinds(), lifecycle <- Target.lifecycles() do
        seam = Target.seam(kind, lifecycle, true)

        assert seam |> Map.keys() |> Enum.sort() == expected
        assert seam["lifecycle"] == lifecycle
      end
    end
  end

  defp machine do
    %Machine{
      id: Ecto.UUID.generate(),
      name: "workshop",
      status: "active",
      tier: "probe",
      revoked_at: nil
    }
  end
end
