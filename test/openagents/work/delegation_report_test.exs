defmodule OpenAgents.Work.DelegationReportTest do
  @moduledoc """
  What a finished delegation is allowed to post into the conversation.

  A delegation's report becomes an assistant message, so it is chat, not a
  terminal window. The regression this pins: a long delegation used to end by
  dumping its whole decoded ACP transcript — hundreds of `Terminal: …` lines,
  each command repeated as title and detail — into the transcript, ending in
  `[transcript truncated]`. The tool-by-tool log belongs to the live
  delegation rail; the message carries what the agent said.
  """
  use OpenAgents.DataCase

  alias OpenAgents.Conversations.Message
  alias OpenAgents.Support.FakeController
  alias OpenAgents.{Accounts, Conversations, Machines, Work}

  @record_separator <<30>>
  @unit_separator <<31>>

  test "a completed delegation reports the agent's prose, never its tool log" do
    %{conversation: conversation, machine: machine} = delegation_owner("deleg-report-prose")

    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.chunk(caller, request_id, noisy_transcript())

      FakeController.exit(caller, request_id, %{
        "status" => "completed",
        "stop_reason" => "end_turn",
        "session_id" => "acp-report-1",
        "duration_ms" => 118_000,
        "truncated" => false,
        "detail" => ""
      })
    end)

    job = run_delegation(conversation, machine)
    assert job.status == "completed"
    content = report_content(job)

    # The agent's own words, the session line the resume path parses, and the
    # one tool call that failed — the parts that explain the outcome.
    assert content =~ "Delegation to claude"
    assert content =~ "Session: acp-report-1"
    assert content =~ "I read the failing test and fixed the selector."
    assert content =~ "Edit: chat_live.ex (failed)"

    # Never the log of everything it typed.
    refute content =~ "Terminal:"
    refute content =~ "/usr/bin/bash -lc"
    refute content =~ "[transcript truncated]"

    # The work is still named, and the whole message stays chat-sized.
    assert content =~ "The agent ran 61 tool calls on the computer."
    assert String.length(content) < 1_000
  end

  test "cancelling a delegation reports the cancellation, never a partial transcript" do
    %{conversation: conversation, machine: machine} = delegation_owner("deleg-report-cancel")
    test_pid = self()

    # A delegation that streams and never returns: the owner stops it from the
    # live panel while the tool log is still growing.
    connect(machine.id, fn {:agent, request_id, _payload, caller} ->
      FakeController.chunk(caller, request_id, noisy_transcript())
      send(test_pid, :delegation_streaming)
    end)

    {:ok, started} = Work.start_delegation(delegation_attributes(conversation, machine))
    assert eventually(fn -> Work.get_job!(started.id).status == "running" end)
    assert_receive :delegation_streaming

    :ok = Work.cancel_active_delegations(conversation.id)
    assert eventually(fn -> Work.get_job!(started.id).status == "cancelled" end)

    content = started.id |> Work.get_job!() |> report_content()

    assert content =~ "Delegation cancelled by the owner."
    refute content =~ "Terminal:"
    refute content =~ "/usr/bin/bash -lc"
    refute content =~ "[transcript truncated]"
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # One realistic delegation stream: a sentence of prose, 60 successful
  # terminal calls whose title and detail both carry the command, one failed
  # edit, and a permission note.
  defp noisy_transcript do
    command = ~s(/usr/bin/bash -lc "sed -n 1,200p lib/openagents_web/live/chat_live.ex")

    terminals =
      Enum.map_join(1..60, "", fn index ->
        id = "toolu_0#{index}"

        frame("T", [id, "0", "execute", encode("Terminal"), ""]) <>
          frame("T", [id, "1", "execute", encode(command), encode(command)])
      end)

    "I read the failing test and fixed the selector.\n" <>
      terminals <>
      frame("T", [
        "toolu_0edit",
        "2",
        "edit",
        encode("chat_live.ex"),
        encode("User refused permission")
      ]) <> frame("N", [encode("Permission denied: Edit"), "warn"])
  end

  defp frame(kind, fields) do
    @record_separator <> Enum.join([kind | fields], @unit_separator) <> "\n"
  end

  defp encode(text), do: Base.encode64(text)

  defp run_delegation(conversation, machine) do
    {:ok, job} = Work.start_delegation(delegation_attributes(conversation, machine))

    assert eventually(fn -> Work.get_job!(job.id).status in Work.Job.terminal_statuses() end)

    Work.get_job!(job.id)
  end

  # The assistant message the delegation posted into the conversation — the row
  # the owner actually reads.
  defp report_content(job) do
    Repo.get_by!(Message, work_job_id: job.id, role: "assistant").content
  end

  defp delegation_owner(login) do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)

    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "report-box-#{login}",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/tmp/openagents-work"]
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    %{user: user, conversation: conversation, machine: machine}
  end

  defp connect(machine_id, script) do
    start_supervised!({FakeController, machine_id: machine_id, script: script})
  end

  defp delegation_attributes(conversation, machine) do
    owner = Conversations.get_conversation_owner!(conversation)

    %{
      conversation_id: conversation.id,
      owner_visitor_id: owner.id,
      machine_id: machine.id,
      surface: "text",
      goal: "Delegate to claude on #{machine.name}: fix the failing test",
      kind: "delegation",
      delegation: %{
        "agent_id" => "claude",
        "machine_id" => machine.id,
        "machine_name" => machine.name,
        "prompt" => "fix the failing test",
        "cwd" => "/tmp/openagents-work",
        "timeout_ms" => 3_600_000
      },
      authority_snapshot: %{
        "machine_tier" => machine.tier,
        "roots" => machine.roots,
        "cwd" => "/tmp/openagents-work",
        "agent_id" => "claude",
        "machine_name" => machine.name
      },
      budget_snapshot: %{
        "wall_clock_ms" => 3_600_000,
        "maximum_prompt_bytes" => 8_000,
        "maximum_report_bytes" => 8_000
      }
    }
  end

  # The delegation runs in a supervised background process; the shared sandbox
  # makes its writes visible here.
  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end
end
