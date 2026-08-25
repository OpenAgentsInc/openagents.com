defmodule OpenAgents.Effects.DatabaseConstraintsTest do
  @moduledoc """
  EFFECT-001, at the database: the CHECK constraints on `effects` reject
  malformed rows even when the insert bypasses the application changeset.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Repo

  @insert_effects """
  INSERT INTO effects
    (id, kind, payload, payload_digest, source_kind, source_id, idempotency_key,
     status, attempts, maximum_attempts, available_at,
     lease_owner, lease_expires_at, claimed_at, completed_at, last_error,
     inserted_at, updated_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
          $12, $13, $14, $15, $16, $17, $18)
  """

  setup do
    base = %{
      id: uuid(),
      kind: "test.kind",
      payload: %{},
      payload_digest: "sha256:" <> String.duplicate("0", 64),
      source_kind: "test_source",
      source_id: uuid_string(),
      idempotency_key: uuid_string(),
      status: "pending",
      attempts: 0,
      maximum_attempts: 5,
      available_at: now(),
      lease_owner: nil,
      lease_expires_at: nil,
      claimed_at: nil,
      completed_at: nil,
      last_error: nil,
      inserted_at: now(),
      updated_at: now()
    }

    {:ok, base: base}
  end

  describe "effects_lease_pair_check" do
    test "a lease owner without an expiry is refused", %{base: base} do
      assert {:error, %Postgrex.Error{} = error} =
               Repo.query(@insert_effects, values(%{base | lease_owner: "worker-1"}))

      assert error.postgres.constraint == "effects_lease_pair_check"
    end

    test "an expiry without an owner is refused", %{base: base} do
      assert {:error, %Postgrex.Error{} = error} =
               Repo.query(@insert_effects, values(%{base | lease_expires_at: now()}))

      assert error.postgres.constraint == "effects_lease_pair_check"
    end
  end

  describe "effects_status_shape_check" do
    test "a claimed effect without a lease and claimed_at is refused", %{base: base} do
      assert {:error, %Postgrex.Error{} = error} =
               Repo.query(@insert_effects, values(%{base | status: "claimed"}))

      assert error.postgres.constraint == "effects_status_shape_check"
    end

    test "a done effect with an owner is refused", %{base: base} do
      completed_at = now()

      assert {:error, %Postgrex.Error{} = error} =
               Repo.query(
                 @insert_effects,
                 values(%{
                   base
                   | status: "done",
                     lease_owner: "worker-1",
                     lease_expires_at: completed_at,
                     completed_at: completed_at
                 })
               )

      assert error.postgres.constraint == "effects_status_shape_check"
    end
  end

  defp values(attrs) do
    [
      attrs.id,
      attrs.kind,
      attrs.payload,
      attrs.payload_digest,
      attrs.source_kind,
      attrs.source_id,
      attrs.idempotency_key,
      attrs.status,
      attrs.attempts,
      attrs.maximum_attempts,
      attrs.available_at,
      attrs.lease_owner,
      attrs.lease_expires_at,
      attrs.claimed_at,
      attrs.completed_at,
      attrs.last_error,
      attrs.inserted_at,
      attrs.updated_at
    ]
  end

  defp uuid, do: Ecto.UUID.dump!(Ecto.UUID.generate())
  defp uuid_string, do: Ecto.UUID.generate()
  defp now, do: DateTime.utc_now()
end
