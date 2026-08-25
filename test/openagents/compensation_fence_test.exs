defmodule OpenAgents.CompensationFenceTest do
  @moduledoc """
  COMPENSATION-001 and append-only invariants, at the database. Every claim
  bypasses the Ecto changeset and writes raw SQL, because the property is that
  PostgreSQL refuses the row or mutation — not that the application declines
  to build it.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Conversations
  alias OpenAgents.Repo

  describe "compensation policies can never grant payout authority" do
    test "a policy receipt with payout_authority true is refused" do
      assert {:error, %Postgrex.Error{} = error} =
               Repo.query(
                 """
                 INSERT INTO compensation_policy_receipts
                   (id, policy_id, version, policy_digest, rules, actor_id, auth_method, approval_receipt_ref, inserted_at)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                 """,
                 [
                   uuid(Ecto.UUID.generate()),
                   "sarah.compensation.accounting.v1",
                   1,
                   hex(),
                   %{"payout_authority" => true},
                   "operator:test",
                   "test_session",
                   "approval:policy:payout:#{System.unique_integer([:positive])}",
                   now()
                 ]
               )

      assert error.postgres.constraint == "compensation_policy_no_payout"
    end
  end

  describe "compensation accounting tables are append-only" do
    setup do
      user = github_user("compensation-fence-#{System.unique_integer([:positive])}")
      {:ok, conversation} = Conversations.ensure_conversation(user)
      {:ok, %{turn: turn}} = Conversations.create_turn(conversation, "Use a module.")

      tool_step = setup_tool_step!(turn)
      policy = insert_policy!()
      allocation = insert_module_allocation!(policy)
      outcome_decision = insert_outcome_decision!(tool_step)
      event = insert_event!(tool_step, policy, outcome_decision)
      share = insert_share!(event)
      adjustment = insert_adjustment!(policy, event)
      statement = insert_statement!(policy)

      %{
        rows: %{
          "compensation_policy_receipts" => policy,
          "compensation_module_allocations" => allocation,
          "compensation_outcome_decisions" => outcome_decision,
          "compensation_events" => event,
          "compensation_shares" => share,
          "compensation_adjustments" => adjustment,
          "compensation_statements" => statement
        }
      }
    end

    test "compensation_policy_receipts rejects update and delete", %{rows: rows} do
      assert_rejects_mutation("compensation_policy_receipts", rows)
    end

    test "compensation_module_allocations rejects update and delete", %{rows: rows} do
      assert_rejects_mutation("compensation_module_allocations", rows)
    end

    test "compensation_outcome_decisions rejects update and delete", %{rows: rows} do
      assert_rejects_mutation("compensation_outcome_decisions", rows)
    end

    test "compensation_events rejects update and delete", %{rows: rows} do
      assert_rejects_mutation("compensation_events", rows)
    end

    test "compensation_shares rejects update and delete", %{rows: rows} do
      assert_rejects_mutation("compensation_shares", rows)
    end

    test "compensation_adjustments rejects update and delete", %{rows: rows} do
      assert_rejects_mutation("compensation_adjustments", rows)
    end

    test "compensation_statements rejects update and delete", %{rows: rows} do
      assert_rejects_mutation("compensation_statements", rows)
    end
  end

  defp assert_rejects_mutation(table, rows) do
    id = Map.fetch!(rows, table)

    assert {:error, %Postgrex.Error{} = update_error} =
             Repo.query("UPDATE #{table} SET id = id WHERE id = $1", [id])

    assert update_error.postgres.message =~ "#{table} is append-only"

    assert {:error, %Postgrex.Error{} = delete_error} =
             Repo.query("DELETE FROM #{table} WHERE id = $1", [id])

    assert delete_error.postgres.message =~ "#{table} is append-only"
  end

  defp setup_tool_step!(turn) do
    now = now()
    turn_id = uuid(turn.id)
    receipt_id = insert_turn_receipt!(turn_id, now)
    insert_tool_step!(turn_id, receipt_id, now)
  end

  defp insert_turn_receipt!(turn_id, now) do
    insert!(
      """
      INSERT INTO turn_receipts
        (id, turn_id, model_id, persona_id, persona_digest, role_id, role_digest,
         instruction_digest, input_digest, input_message_count, input_bytes,
         provider_started_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        turn_id,
        "test-model",
        "test-persona",
        hex(),
        "test-role",
        hex(),
        hex(),
        hex(),
        0,
        0,
        now,
        now,
        now
      ]
    )
  end

  defp insert_tool_step!(turn_id, turn_receipt_id, now) do
    insert!(
      """
      INSERT INTO turn_tool_steps
        (id, turn_id, turn_receipt_id, sequence, provider_call_id, provider_item_id,
         provider_response_id, tool_name, tool_version, module_id, side_effect_class,
         invocation_key, catalog_digest, raw_arguments, argument_digest, requested_at,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        turn_id,
        turn_receipt_id,
        1,
        "call-#{System.unique_integer([:positive])}",
        "item-#{System.unique_integer([:positive])}",
        "response-#{System.unique_integer([:positive])}",
        "host",
        1,
        "sarah.host",
        "read_only",
        hex(),
        hex(),
        "{}",
        hex(),
        now,
        now,
        now
      ]
    )
  end

  defp insert_policy! do
    insert!(
      """
      INSERT INTO compensation_policy_receipts
        (id, policy_id, version, policy_digest, rules, actor_id, auth_method, approval_receipt_ref, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        "sarah.compensation.accounting.v1",
        1,
        hex(),
        %{"payout_authority" => false},
        "operator:test",
        "test_session",
        "approval:policy:valid:#{System.unique_integer([:positive])}",
        now()
      ]
    )
  end

  defp insert_module_allocation!(policy_id) do
    insert!(
      """
      INSERT INTO compensation_module_allocations
        (id, policy_receipt_id, module_id, module_version, artifact_digest, contribution_ref,
         allocation_ppm, lineage_digest, actor_id, approval_receipt_ref, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        policy_id,
        "sarah.host",
        1,
        hex(),
        "OpenAgentsInc/openagents.com",
        1_000_000,
        hex(),
        "operator:test",
        "approval:allocation:#{System.unique_integer([:positive])}",
        now()
      ]
    )
  end

  defp insert_outcome_decision!(tool_step_id) do
    insert!(
      """
      INSERT INTO compensation_outcome_decisions
        (id, tool_step_id, invocation_key, outcome_receipt_ref, outcome_digest, decision,
         reason_code, actor_id, auth_method, decision_receipt_ref, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        tool_step_id,
        hex(),
        "outcome:decision:#{System.unique_integer([:positive])}",
        hex(),
        "accepted",
        "verified_outcome",
        "outcome-reviewer:test",
        "test_session",
        "approval:decision:#{System.unique_integer([:positive])}",
        now()
      ]
    )
  end

  defp insert_event!(tool_step_id, policy_id, outcome_decision_id) do
    insert!(
      """
      INSERT INTO compensation_events
        (id, tool_step_id, policy_receipt_id, outcome_decision_id, module_id, module_version,
         artifact_digest, invocation_key, outcome_receipt_ref, technical_units, eligible_units,
         classification, reason_code, event_digest, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        tool_step_id,
        policy_id,
        outcome_decision_id,
        "sarah.host",
        1,
        hex(),
        hex(),
        "outcome:event:#{System.unique_integer([:positive])}",
        0,
        0,
        "ineligible",
        "outcome_rejected",
        hex(),
        now()
      ]
    )
  end

  defp insert_share!(event_id) do
    insert!(
      """
      INSERT INTO compensation_shares
        (id, event_id, contribution_ref, allocation_ppm, allocated_units, share_digest, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        event_id,
        "OpenAgentsInc/openagents.com",
        1_000_000,
        0,
        hex(),
        now()
      ]
    )
  end

  defp insert_adjustment!(policy_id, event_id) do
    insert!(
      """
      INSERT INTO compensation_adjustments
        (id, event_id, policy_receipt_id, contribution_ref, kind, delta_units, reason_code,
         actor_id, auth_method, adjustment_receipt_ref, adjustment_digest, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        event_id,
        policy_id,
        "OpenAgentsInc/openagents.com",
        "refund",
        -10,
        "customer_refund",
        "operator:test",
        "test_session",
        "approval:adjustment:#{System.unique_integer([:positive])}",
        hex(),
        now()
      ]
    )
  end

  defp insert_statement!(policy_id) do
    now = now()

    insert!(
      """
      INSERT INTO compensation_statements
        (id, policy_receipt_id, contribution_ref, cutoff_at, gross_units, adjustment_units,
         net_units, event_count, state, statement_digest, actor_id, statement_receipt_ref, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
      RETURNING id
      """,
      [
        uuid(Ecto.UUID.generate()),
        policy_id,
        "OpenAgentsInc/openagents.com",
        now,
        100,
        -50,
        50,
        1,
        "reconciled",
        hex(),
        "operator:test",
        "approval:statement:#{System.unique_integer([:positive])}",
        now
      ]
    )
  end

  defp insert!(sql, params) do
    %{rows: [[id]]} = Repo.query!(sql, params)
    id
  end

  defp uuid(value), do: Ecto.UUID.dump!(value)
  defp now, do: DateTime.utc_now()
  defp hex, do: String.duplicate("0", 64)
end
