defmodule OpenAgents.Forge.AssignmentStartRaceTest do
  @moduledoc """
  A finalized assignment is never resurrected by a slower starter.

  `start_target/7` read the assignment's state and then wrote `running` back,
  with nothing holding the row between the two. A run that finalized inside
  that window had already moved the assignment terminal and revoked its
  credential, so the write left an attempt that looked live and could not
  authenticate: `usable?/1` refuses a revoked credential, and every push the
  attempt tried failed while its state said the attempt was still going.

  The window is microseconds wide, which is why no production run ever fell
  into it and why asserting the fix by inspection would prove nothing. These
  tests open it deliberately. Ecto publishes a `[:open_agents, :repo, :query]`
  event after every query, in the process that made it, so a handler attached
  to that event runs between one query the starter makes and the next — which
  is the window, exactly. Finalizing the assignment from there puts the
  finalizer inside it without a seam in the code under test.

  The invariant the whole case is about, and the one that fails when the guard
  and the write come apart, is stated once in
  `refute_live_assignment_with_revoked_credential/0`: no assignment is ever in
  a non-terminal state while its credential is revoked.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.{Assignment, AssignmentCredential, Assignments}
  alias OpenAgents.Issues
  alias OpenAgents.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    original_api = Application.get_env(:openagents, :box_api)
    original_key = Application.get_env(:openagents, :box_api_key)

    Application.put_env(:openagents, :box_api,
      base_url: "https://box-api.internal",
      request_options: [plug: &stub_provider/1]
    )

    Application.put_env(:openagents, :box_api_key, "assignment-start-race-test")

    on_exit(fn ->
      restore(:box_api, original_api)
      restore(:box_api_key, original_key)
    end)

    :ok
  end

  describe "a run that finalizes while the starter is writing" do
    test "leaves the assignment terminal and its credential revoked" do
      assignment = admit("start-race-window", "bx_racetst2")

      finalize_inside_the_starter_window(assignment)

      _result = Assignments.start_running(assignment, nil)

      refute_live_assignment_with_revoked_credential()

      current = Repo.get!(Assignment, assignment.id)
      credential = Assignments.credential(assignment)

      assert current.state == "completed"
      refute is_nil(credential.revoked_at)
    end
  end

  describe "a starter that arrives after the run finished" do
    test "reports that it lost and writes nothing" do
      assignment = admit("start-race-late", "bx_racetst3")

      assert {:ok, _finished} = Assignments.finish(assignment, "completed")

      assert {:already_finished, current} = Assignments.start_running(assignment, nil)

      assert current.state == "completed"
      assert is_nil(current.started_at)
      assert is_nil(current.run_id)
      refute_live_assignment_with_revoked_credential()
    end

    test "reports that it won when the assignment is still live" do
      assignment = admit("start-race-live", "bx_racetst4")

      assert {:ok, started} = Assignments.start_running(assignment, nil)

      assert started.state == "running"
      refute is_nil(started.started_at)
      refute_live_assignment_with_revoked_credential()
    end
  end

  # The invariant, as a query. An assignment whose credential is revoked has
  # reached a terminal state, so a row that is neither `completed`, `failed`,
  # nor `cancelled` while carrying a revoked credential is an attempt that
  # cannot do the work its state claims it is doing.
  defp refute_live_assignment_with_revoked_credential do
    live =
      Repo.all(
        from assignment in Assignment,
          join: credential in AssignmentCredential,
          on: credential.assignment_id == assignment.id,
          where:
            assignment.state not in ^Assignment.terminal_states() and
              not is_nil(credential.revoked_at),
          select: {assignment.id, assignment.state}
      )

    assert live == [],
           "assignments are live while their credential is revoked: #{inspect(live)}"
  end

  # Finalize the assignment the first time the starter touches its table, and
  # once only. The handler runs in the process that made the query, so this
  # lands between that query and whatever the starter does next — the window
  # the defect lived in. `finish/4` queries the same table, which is what the
  # flag stops from re-entering.
  defp finalize_inside_the_starter_window(%Assignment{} = assignment) do
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:open_agents, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "forge_assignments" and Process.get(:race_armed) do
          Process.delete(:race_armed)
          {:ok, _finished} = Assignments.finish(assignment, "completed")
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Process.put(:race_armed, true)
    :ok
  end

  defp admit(owner_slug, box_id) do
    owner = repository_user_fixture(owner_slug)
    repository = repository_with_member_fixture(owner, %{visibility: "public"}, "owner")

    {:ok, issue} = Issues.create_issue(repository, %{title: "Prove the guard", body: "A body."})

    {:ok, conversation} = Conversations.ensure_conversation(owner)

    {:ok, box} =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: box_id,
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert()

    branch = "agent/issue-#{issue.number}"

    assert {:ok, assignment, _plaintext} =
             Assignments.create(%{
               "target_kind" => "box",
               "box_id" => box.box_id,
               "conversation_id" => conversation.id,
               "repository_id" => repository.id,
               "issue_number" => issue.number,
               "branch" => branch,
               "requesting_user" => owner,
               "requesting_principal" => owner
             })

    # `create/1` starts the attempt, and its run worker keeps polling a stubbed
    # provider for as long as it lives. These cases drive the transition
    # themselves, so retire the worker first and then put the row back where a
    # starter finds it. The assertion is what keeps the fixture honest: a
    # worker that finalized the attempt anyway would make this reset the very
    # resurrection the case is about, so it fails here instead.
    stop_run_worker(assignment)

    current = Repo.get!(Assignment, assignment.id)
    refute Assignment.terminal?(current)

    current
    |> Ecto.Changeset.change(%{state: "admitted", started_at: nil, run_id: nil})
    |> Repo.update!()
  end

  defp stop_run_worker(%Assignment{run_id: run_id}) when is_binary(run_id) do
    case Registry.lookup(OpenAgents.BoxRunRegistry, run_id) do
      [{pid, _value}] ->
        reference = Process.monitor(pid)
        _ = GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^reference, :process, ^pid, _reason}

      [] ->
        :ok
    end
  end

  defp stop_run_worker(%Assignment{}), do: :ok

  # The run exists only so `create/1` reaches its return. A dispatch that
  # answers with a pid parks the worker on its poll interval, which leaves the
  # run non-terminal for far longer than these cases take, and `admit/2` stops
  # the worker before it polls.
  defp stub_provider(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)

    case Jason.decode(raw) do
      {:ok, %{"command" => command}} when is_binary(command) ->
        Req.Test.json(conn, %{"stdout" => "4242\n"})

      _other ->
        Req.Test.json(conn, %{
          "box" => %{"id" => requested_box_id(conn), "state" => "ready", "setupStatus" => "done"}
        })
    end
  end

  defp requested_box_id(%Plug.Conn{path_info: ["boxes", box_id | _rest]}), do: box_id
  defp requested_box_id(_conn), do: "bx_racetst2"

  defp restore(key, nil), do: Application.delete_env(:openagents, key)
  defp restore(key, value), do: Application.put_env(:openagents, key, value)
end
