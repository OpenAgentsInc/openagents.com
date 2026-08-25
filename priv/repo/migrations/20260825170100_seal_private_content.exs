defmodule OpenAgents.Repo.Migrations.SealPrivateContent do
  @moduledoc """
  The backfill half of sealing the private content columns nobody searches
  (issue #193).

  Every existing row is sealed under `OpenAgents.ContentVault` and its
  plaintext is nulled, so the words stop resting readable in the same deploy
  that starts sealing new ones. The plaintext columns themselves survive one
  more release for the nodes still writing into them; the contract migration
  drops them after that, the way `machine_pairings.user_id` was dropped a
  release after its last reader.

  It refuses rather than skips. A row that cannot be sealed — no key, or a key
  that does not decode — stops the migration, because a backfill that quietly
  leaves plaintext behind while `OpenAgents.Forge.AtRest` starts publishing the
  column as sealed is the exact claim `EXIT-006` exists to keep off the status
  page. An empty table needs no key, so a fresh database migrates without one.

  One honest limit: `UPDATE` writes a new row version and leaves the old one on
  disk until autovacuum reclaims it, so the plaintext survives in dead tuples
  for a bounded window after this runs. Recorded in
  `docs/2026-08-25-encryption-at-rest.md` rather than implied.
  """

  use Ecto.Migration

  alias OpenAgents.ContentVault

  @batch 500

  # {table, plaintext column, ciphertext column, the columns that bind the
  # seal and whether each is a `uuid`, trigger to disable during migration}.
  # The type is declared rather than sniffed: PostgreSQL hands `uuid` back as
  # a raw 16-byte binary, and a 16-character provider item id would be
  # indistinguishable from one.
  @columns [
    {"voice_transcript_items", "content", "content_ciphertext",
     [
       {"voice_session_id", :uuid},
       {"generation", :plain},
       {"provider_item_id", :plain},
       {"role", :plain}
     ], nil},
    {"voice_sessions", "compaction_summary", "compaction_summary_ciphertext",
     [{"id", :uuid}, {"generation", :plain}], nil},
    {"preference_observations", "summary", "summary_ciphertext",
     [{"owner_visitor_id", :uuid}, {"evidence_digest", :plain}],
     "preference_observations_append_only"},
    {"project_notes", "body", "body_ciphertext",
     [{"project_id", :plain}, {"repository_id", :uuid}, {"kind", :plain}], nil}
  ]

  def up do
    Enum.each(@columns, &with_trigger_disabled(&1, fn col -> convert(col, :seal) end))
  end

  def down do
    Enum.each(@columns, &with_trigger_disabled(&1, fn col -> convert(col, :open) end))
  end

  def run_direct!(repo_module, direction \\ :seal) do
    Enum.each(
      @columns,
      &with_trigger_disabled_direct(repo_module, &1, fn col ->
        convert_with_repo(repo_module, col, direction)
      end)
    )
  end

  defp with_trigger_disabled({table, _plaintext, _ciphertext, _binding, trigger} = col, fun) do
    if trigger do
      repo().query!("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")
    end

    try do
      fun.(col)
    after
      if trigger do
        repo().query!("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}")
      end
    end
  end

  defp with_trigger_disabled_direct(
         repo_module,
         {table, _plaintext, _ciphertext, _binding, trigger} = col,
         fun
       ) do
    if trigger do
      repo_module.query!("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")
    end

    try do
      fun.(col)
    after
      if trigger do
        repo_module.query!("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}")
      end
    end
  end

  defp convert(column, direction) do
    convert_with_repo(repo(), column, direction)
  end

  defp convert_with_repo(
         repo_module,
         {table, plaintext, ciphertext, binding_columns, _trigger} = column,
         direction
       ) do
    {source, target} =
      case direction do
        :seal -> {plaintext, ciphertext}
        :open -> {ciphertext, plaintext}
      end

    %{rows: rows} =
      repo_module.query!(
        """
        SELECT id, #{source}, #{binding_columns |> Enum.map_join(", ", &elem(&1, 0))}
        FROM #{table}
        WHERE #{source} IS NOT NULL
        LIMIT #{@batch}
        """,
        []
      )

    case rows do
      [] ->
        :ok

      rows ->
        Enum.each(rows, fn [id, value | binding] ->
          repo_module.query!(
            "UPDATE #{table} SET #{target} = $1, #{source} = NULL WHERE id = $2",
            [
              converted!(direction, table, plaintext, value, normalize(binding_columns, binding)),
              id
            ]
          )
        end)

        convert_with_repo(repo_module, column, direction)
    end
  end

  defp converted!(:seal, table, plaintext, value, binding) do
    case ContentVault.seal(value, "#{table}.#{plaintext}", binding) do
      {:ok, sealed} ->
        sealed

      {:error, reason} ->
        raise "the #{table}.#{plaintext} backfill cannot seal a row: #{reason}. " <>
                "Provision CONTENT_ENCRYPTION_KEY before migrating; this migration will " <>
                "not leave content readable while the ledger publishes it sealed."
    end
  end

  defp converted!(:open, table, plaintext, value, binding) do
    case ContentVault.open(value, "#{table}.#{plaintext}", binding) do
      {:ok, content} ->
        content

      {:error, reason} ->
        raise "the #{table}.#{plaintext} rollback cannot open a row: #{reason}"
    end
  end

  # PostgreSQL hands back `uuid` columns as raw 16-byte binaries, and the
  # application binds seals to the string form Ecto loads.
  defp normalize(binding_columns, binding) do
    binding_columns
    |> Enum.zip(binding)
    |> Enum.map(fn
      {{_column, :uuid}, value} -> Ecto.UUID.load!(value)
      {{_column, :plain}, value} -> value
    end)
  end
end
