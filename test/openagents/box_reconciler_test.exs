defmodule OpenAgents.BoxReconcilerTest do
  use OpenAgents.DataCase, async: false
  import Ecto.Query

  alias OpenAgents.Box
  alias OpenAgents.Box.{ConversationBox, ReconciliationEvent, Reconciler, Run, Usage}
  alias OpenAgents.{Accounts, Conversations}
  alias OpenAgents.Repo

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_api = Application.get_env(:openagents, :box_api)
    original_key = Application.get_env(:openagents, :box_api_key)

    Application.put_env(
      :openagents,
      :box_api,
      Keyword.merge(original_api || [],
        base_url: "https://box-api.internal",
        ttl_seconds: 3_600,
        idle_timeout_seconds: 1_800,
        reconciliation_interval_ms: 60_000,
        request_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0]
      )
    )

    Application.put_env(:openagents, :box_api_key, "box-reconciler-test")

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)

    {:ok, conversation} = Conversations.ensure_conversation("box-reconciler-owner")
    %{conversation_id: conversation.id}
  end

  test "TTL expiry stops a Box and records the reason", %{conversation_id: conversation_id} do
    box = insert_box(conversation_id, "bx_8bhkse3n")
    age_box(box, 3_601)
    set_box_config(ttl_seconds: 1, idle_timeout_seconds: 3_600)

    expect_list([box.box_id])
    expect_get(box.box_id)
    expect_stop(box.box_id)

    assert {:ok, %{boxes: 1}} = Reconciler.reconcile()
    updated = Repo.get!(ConversationBox, box.id)
    assert updated.stopped_at
    assert updated.stop_reason == "ttl_expired"
    assert updated.lifetime_seconds >= 3_601
  end

  test "idle reclamation leaves a live run alone", %{conversation_id: conversation_id} do
    box = insert_box(conversation_id, "bx_8bhkse3n")
    age_box(box, 3_601)
    insert_run(conversation_id, box.id, "live-run", "running")
    set_box_config(ttl_seconds: 10_000, idle_timeout_seconds: 1)

    expect_list([box.box_id])
    expect_get(box.box_id)

    assert {:ok, _summary} = Reconciler.reconcile()
    refute Repo.get!(ConversationBox, box.id).stopped_at
  end

  test "provider-missing Boxes become terminal and release capacity", %{
    conversation_id: conversation_id
  } do
    box = insert_box(conversation_id, "bx_8bhkse3n")

    expect_list([])

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/boxes/#{box.box_id}"
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end)

    assert {:ok, _summary} = Reconciler.reconcile()
    updated = Repo.get!(ConversationBox, box.id)
    assert updated.state == "archived"
    assert updated.stop_reason == "provider_missing"
    assert updated.stopped_at
  end

  test "provider-terminal state is adopted without another stop request", %{
    conversation_id: conversation_id
  } do
    box = insert_box(conversation_id, "bx_8bhkse3n")

    expect_list([box.box_id])

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/boxes/#{box.box_id}"
      Req.Test.json(conn, %{"box" => %{"id" => box.box_id, "state" => "terminated"}})
    end)

    assert {:ok, _summary} = Reconciler.reconcile()
    updated = Repo.get!(ConversationBox, box.id)
    assert updated.state == "archived"
    assert updated.stop_reason == "provider_terminal"
    assert updated.stopped_at
  end

  test "provider transport failure leaves lifecycle state untouched and backs off", %{
    conversation_id: conversation_id
  } do
    box = insert_box(conversation_id, "bx_8bhkse3n")
    before = Repo.get!(ConversationBox, box.id)

    expect_list([box.box_id])

    for _attempt <- 1..3 do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/boxes/#{box.box_id}"
        Req.Test.transport_error(conn, :econnrefused)
      end)
    end

    assert {:ok, _summary} = Reconciler.reconcile()
    after_failure = Repo.get!(ConversationBox, box.id)
    assert after_failure.state == before.state
    assert after_failure.stopped_at == before.stopped_at
    assert after_failure.reconciliation_failures == 1
    assert after_failure.next_reconciliation_at
  end

  test "provider rate limiting leaves lifecycle state untouched and backs off", %{
    conversation_id: conversation_id
  } do
    box = insert_box(conversation_id, "bx_8bhkse3n")
    before = Repo.get!(ConversationBox, box.id)

    expect_list([box.box_id])

    for _attempt <- 1..3 do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/boxes/#{box.box_id}"
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{})
      end)
    end

    assert {:ok, _summary} = Reconciler.reconcile()
    after_failure = Repo.get!(ConversationBox, box.id)
    assert after_failure.state == before.state
    assert after_failure.stopped_at == before.stopped_at
    assert after_failure.reconciliation_failures == 1
    assert after_failure.reconciliation_error == "box_rate_limited"
  end

  test "a provider leak is reported and stopped", %{conversation_id: conversation_id} do
    box = insert_box(conversation_id, "bx_8bhkse3n")
    leak_id = "bx_8bhkse4n"

    expect_list([box.box_id, leak_id])
    expect_get(box.box_id)
    expect_stop(leak_id)

    assert {:ok, _summary} = Reconciler.reconcile()

    assert %ReconciliationEvent{
             provider_box_id: ^leak_id,
             event_type: "leak",
             reason: "provider_box_without_ledger_claim",
             handled_at: %DateTime{}
           } = Repo.get_by!(ReconciliationEvent, provider_box_id: leak_id)
  end

  test "an unmarked provider leak is reported and left running", %{
    conversation_id: conversation_id
  } do
    box = insert_box(conversation_id, "bx_8bhkse3n")
    foreign_id = "bx_foreign1"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/boxes"

      Req.Test.json(conn, %{
        "boxes" => [
          %{"id" => box.box_id, "state" => "ready", "name" => Box.provider_ownership_marker()},
          %{"id" => foreign_id, "state" => "ready", "name" => "developer-box"}
        ]
      })
    end)

    expect_get(box.box_id)
    assert {:ok, _summary} = Reconciler.reconcile()

    assert %ReconciliationEvent{
             provider_box_id: ^foreign_id,
             reason: "provider_box_without_ledger_claim",
             handled_at: nil
           } = Repo.get_by!(ReconciliationEvent, provider_box_id: foreign_id)
  end

  test "repeated passes do not issue a second stop", %{conversation_id: conversation_id} do
    box = insert_box(conversation_id, "bx_8bhkse3n")
    age_box(box, 3_601)
    set_box_config(ttl_seconds: 1, idle_timeout_seconds: 3_600)

    expect_list([box.box_id])
    expect_get(box.box_id)
    expect_stop(box.box_id)
    assert {:ok, _summary} = Reconciler.reconcile()

    expect_list([box.box_id])
    assert {:ok, _summary} = Reconciler.reconcile()
  end

  test "the pass skips settled stopped history", %{conversation_id: conversation_id} do
    active = insert_box(conversation_id, "bx_8bhkse3p")
    settled_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    historical = insert_box(conversation_id, "bx_history")

    Repo.update_all(
      from(box in ConversationBox, where: box.id == ^historical.id),
      set: [stopped_at: settled_at, usage_settled_at: settled_at]
    )

    expect_list([active.box_id])
    expect_get(active.box_id)

    assert {:ok, %{boxes: 1}} = Reconciler.reconcile()
  end

  test "usage totals are readable by conversation and owner", %{conversation_id: conversation_id} do
    box = insert_box(conversation_id, "bx_8bhkse3n")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(box in ConversationBox, where: box.id == ^box.id),
      set: [stopped_at: now, lifetime_seconds: 90, settled_cost_microusd: 12_345]
    )

    assert %{lifetime_seconds: 90, settled_cost_microusd: 12_345, boxes: 1} =
             Usage.for_conversation(conversation_id)
  end

  test "usage totals include Boxes owned by a user" do
    {:ok, user} = Accounts.upsert_github_user(profile(81_109, "reconciler-owner"))
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx_8bhkse3n")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(item in ConversationBox, where: item.id == ^box.id),
      set: [stopped_at: now, lifetime_seconds: 120, settled_cost_microusd: 99]
    )

    assert %{lifetime_seconds: 120, settled_cost_microusd: 99, boxes: 1} =
             Usage.for_owner(user.id)
  end

  test "the reconciler is supervised", %{conversation_id: _conversation_id} do
    pid =
      start_supervised!(
        {Reconciler,
         interval_ms: 60_000, initial_delay_ms: 60_000, name: :box_reconciler_test_process}
      )

    assert :sys.get_state(pid).interval_ms == 60_000
  end

  defp insert_box(conversation_id, box_id) do
    %ConversationBox{}
    |> ConversationBox.changeset(%{
      conversation_id: conversation_id,
      box_id: box_id,
      state: "ready",
      setup_status: "done"
    })
    |> Repo.insert!()
  end

  defp insert_run(conversation_id, box_id, key, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Run{}
    |> Run.changeset(%{
      conversation_id: conversation_id,
      conversation_box_id: box_id,
      requesting_principal: %{"type" => "user", "id" => "reconciler-test"},
      command: "true",
      idempotency_key: key,
      state: state,
      run_directory: "/home/box-user/.openagents/box-runs/#{key}",
      admitted_at: now,
      started_at: now,
      deadline_at: DateTime.add(now, 3_600, :second)
    })
    |> Repo.insert!()
  end

  defp age_box(box, seconds) do
    inserted_at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.update_all(from(item in ConversationBox, where: item.id == ^box.id),
      set: [inserted_at: inserted_at]
    )
  end

  defp expect_list(box_ids) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/boxes"

      Req.Test.json(conn, %{
        "boxes" =>
          Enum.map(
            box_ids,
            &%{
              "id" => &1,
              "state" => "ready",
              "name" => Box.provider_ownership_marker()
            }
          )
      })
    end)
  end

  defp expect_get(box_id) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/boxes/#{box_id}"

      Req.Test.json(conn, %{
        "box" => %{"id" => box_id, "state" => "ready", "name" => Box.provider_ownership_marker()}
      })
    end)
  end

  defp expect_stop(box_id) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/boxes/#{box_id}/stop"
      Req.Test.json(conn, %{"box" => %{"id" => box_id, "state" => "archiving"}})
    end)
  end

  defp set_box_config(overrides) do
    original = Application.get_env(:openagents, :box_api)
    Application.put_env(:openagents, :box_api, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:openagents, :box_api, original) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  defp profile(id, login) do
    %{
      github_id: id,
      github_login: login,
      github_avatar_url: "https://avatars.githubusercontent.com/u/#{id}?v=4"
    }
  end
end
