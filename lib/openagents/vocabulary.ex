defmodule OpenAgents.Vocabulary do
  @moduledoc """
  The ledger of durable names that keep the word `machine`.

  The product says computer. `docs/taxonomy.md` settled that, and issue #134
  settled what happens to the names underneath it: a `machine` name stays where
  something outside this release can observe or replay it, and moves to
  `computer` where it cannot. PostgreSQL is the clearest case of the first —
  a table, column, constraint, or index name is read by rows an earlier release
  wrote — so this module enumerates every durable name that is exempt, and
  `OpenAgents.VocabularyTest` derives the live population from
  `information_schema` and `pg_catalog` and fails when the two disagree.

  The point is not the list. The point is that a new `machine`-named durable
  surface cannot appear without someone adding it here and saying why, and a
  removed one cannot linger here pretending to exist. See `INVARIANTS.md`,
  CANON-002.

  This ledger covers PostgreSQL only. The wire half of the same decision — the
  controller protocol `openagents.computer.v1`, the `.v1` tool schemas, the
  published response keys, the PubSub topics and Horde registry keys — is held
  by its own contracts, because no query enumerates it.
  """

  @tables ~w(machine_pairings machines repository_machine_grants)

  @columns [
    {"forge_assignments", "machine_id"},
    {"inference_grants", "machine_id"},
    {"machine_pairings", "machine_id"},
    {"repository_machine_grants", "machine_id"},
    {"work_jobs", "machine_id"}
  ]

  @constraints [
    {"forge_assignments", "forge_assignments_machine_id_fkey"},
    {"inference_grants", "inference_grants_machine_id_fkey"},
    {"machine_pairings", "machine_pairings_machine_id_fkey"},
    # The owner column is gone from the schema and unread by any code, but the
    # column and this key survive one more release: dropping them during a
    # rolling replacement would break this table for the nodes still running
    # the release that declares `belongs_to :user`. The contract migration
    # removes both once that release is off every node.
    {"machine_pairings", "machine_pairings_user_id_fkey"},
    {"machine_pairings", "machine_pairings_pkey"},
    {"machine_pairings", "machine_pairings_status_check"},
    {"machine_pairings", "machine_pairings_tier_check"},
    {"machines", "machines_pkey"},
    {"machines", "machines_status_check"},
    {"machines", "machines_tier_check"},
    {"machines", "machines_token_expiry_after_creation"},
    {"machines", "machines_user_id_fkey"},
    {"repository_machine_grants", "repository_machine_grants_created_by_user_id_fkey"},
    {"repository_machine_grants", "repository_machine_grants_machine_id_fkey"},
    {"repository_machine_grants", "repository_machine_grants_operations_allowed"},
    {"repository_machine_grants", "repository_machine_grants_operations_present"},
    {"repository_machine_grants", "repository_machine_grants_pkey"},
    {"repository_machine_grants", "repository_machine_grants_repository_id_fkey"},
    {"work_jobs", "work_jobs_machine_id_fkey"}
  ]

  @indexes [
    {"forge_assignments", "forge_assignments_machine_id_index"},
    {"forge_assignments", "forge_assignments_one_active_machine_index"},
    {"inference_grants", "inference_grants_machine_id_index"},
    {"machine_pairings", "machine_pairings_code_digest_index"},
    {"machine_pairings", "machine_pairings_expires_at_index"},
    {"machine_pairings", "machine_pairings_pkey"},
    {"machines", "machines_pkey"},
    {"machines", "machines_token_digest_index"},
    {"machines", "machines_user_id_index"},
    {"repository_machine_grants", "repository_machine_grants_machine_id_index"},
    {"repository_machine_grants", "repository_machine_grants_pkey"},
    {"repository_machine_grants", "repository_machine_grants_repository_id_machine_id_index"},
    {"work_jobs", "work_jobs_machine_id_inserted_at_index"}
  ]

  @doc "Tables whose name keeps `machine`."
  @spec tables() :: [String.t()]
  def tables, do: @tables

  @doc "`{table, column}` pairs whose column name keeps `machine`."
  @spec columns() :: [{String.t(), String.t()}]
  def columns, do: @columns

  @doc "`{table, constraint}` pairs whose constraint name keeps `machine`."
  @spec constraints() :: [{String.t(), String.t()}]
  def constraints, do: @constraints

  @doc "`{table, index}` pairs whose index name keeps `machine`."
  @spec indexes() :: [{String.t(), String.t()}]
  def indexes, do: @indexes
end
