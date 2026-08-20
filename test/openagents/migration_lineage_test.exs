defmodule OpenAgents.MigrationLineageTest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.MigrationLineage
  alias OpenAgents.Repo

  @snapshot_ref "local-snapshot-20260820"

  test "the baseline map partitions every current migration" do
    %{data: map, digest: digest} = MigrationLineage.map!()

    current_versions =
      "priv/repo/migrations/*.exs"
      |> Path.wildcard()
      |> Enum.map(fn path ->
        path |> Path.basename() |> String.slice(0, 14) |> String.to_integer()
      end)
      |> MapSet.new()

    baseline_versions = Enum.map(map["baseline_entries"], & &1["current_version"])

    classified_versions =
      map["shared_versions"] ++
        baseline_versions ++
        map["reconciliation_versions_to_run"] ++ map["new_versions_to_run"]

    assert MapSet.new(classified_versions) == current_versions
    assert length(classified_versions) == MapSet.size(current_versions)
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a current-lineage database is classified without mutation" do
    assert {:ok, result} = MigrationLineage.classify(Repo)
    assert result.classification == "current"
    assert result.bridge_state == "complete"
  end

  test "the known prior lineage is baselined once without deleting account data" do
    user = repository_user_fixture("lineage-account")
    prepare_prior_lineage!()

    assert {:ok, before} = MigrationLineage.classify(Repo)
    assert before.classification == "prior"
    assert before.required_facts_missing == 0

    assert {:ok, result} = MigrationLineage.baseline(Repo, @snapshot_ref)
    assert result.classification == "prior_baselined"
    assert result.changed
    assert result.snapshot_ref == @snapshot_ref
    assert user_exists?(user.id)
    assert column_exists?("users", "browser_key_hash")
    assert index_exists?("users_browser_key_hash_index")

    assert {:ok, repeated} = MigrationLineage.baseline(Repo, @snapshot_ref)
    refute repeated.changed

    encoded = MigrationLineage.command!(Repo, "check", nil)
    refute encoded =~ user.github_login
    assert Jason.decode!(encoded)["classification"] == "prior_baselined"
  end

  test "an unknown or partially modified lineage is refused" do
    prepare_prior_lineage!()
    [first_baseline | _rest] = baseline_versions()
    insert_version!(first_baseline)

    assert {:ok, %{classification: "prior_partial"}} = MigrationLineage.classify(Repo)

    assert {:error, :partial_lineage_forbidden} =
             MigrationLineage.baseline(Repo, @snapshot_ref)

    Repo.query!("DELETE FROM schema_migrations")
    insert_version!(20_260_101_000_000)

    assert {:ok, %{classification: "unknown"}} = MigrationLineage.classify(Repo)

    assert {:error, :lineage_not_baselineable} =
             MigrationLineage.baseline(Repo, @snapshot_ref)
  end

  test "baseline mutation requires a bounded snapshot reference" do
    assert {:error, :invalid_snapshot_reference} = MigrationLineage.baseline(Repo, "missing")

    assert {:error, :invalid_snapshot_reference} =
             MigrationLineage.baseline(Repo, "snapshot/contains/path")
  end

  defp prepare_prior_lineage! do
    Repo.query!("DELETE FROM schema_migrations")
    Repo.query!("DROP INDEX users_browser_key_hash_index")
    Repo.query!("ALTER TABLE users DROP COLUMN browser_key_hash")
    Repo.query!("ALTER TABLE users ALTER COLUMN github_avatar_url TYPE text")

    Repo.query!("""
    CREATE UNIQUE INDEX forge_builds_repo_sha_target_id_index
        ON forge_builds (repo, sha, target_id)
    """)

    %{data: map} = MigrationLineage.map!()
    Enum.each(map["prior_signature_versions"], &insert_version!/1)
  end

  defp baseline_versions do
    %{data: map} = MigrationLineage.map!()
    Enum.map(map["baseline_entries"], & &1["current_version"])
  end

  defp insert_version!(version) do
    Repo.query!(
      "INSERT INTO schema_migrations (version, inserted_at) VALUES ($1, NOW())",
      [version]
    )
  end

  defp column_exists?(table, column) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
        [table, column]
      )

    count == 1
  end

  defp index_exists?(index) do
    %{num_rows: count} =
      Repo.query!("SELECT 1 FROM pg_indexes WHERE indexname = $1", [index])

    count == 1
  end

  defp user_exists?(id) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM users WHERE id::text = $1", [id])
    count == 1
  end
end
