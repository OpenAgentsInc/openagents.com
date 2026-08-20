defmodule OpenAgents.MigrationLineage do
  @moduledoc """
  Classifies and safely baselines the known nonempty database lineage.

  The baseline is an explicit compatibility bridge, not a general migration
  repair tool. It refuses unknown and partially modified lineages. Applying it
  requires a bounded snapshot reference and is admitted only in tests or in
  staging at Gate 13 or later.
  """

  alias Ecto.Adapters.SQL

  @lock_id 42_424_242
  @map_file "migration_lineages/prior-2026-08-19.json"
  @snapshot_pattern ~r/\A[a-z0-9][a-z0-9-]{7,127}\z/

  @type classification ::
          :empty | :current | :prior | :prior_baselined | :prior_partial | :unknown

  @doc "Returns a bounded classification without changing the database."
  @spec classify(module()) :: {:ok, map()} | {:error, atom()}
  def classify(repo) when is_atom(repo) do
    with :ok <- ensure_admitted() do
      {:ok, classify_repo(repo, load_map!())}
    end
  end

  @doc "Applies the known baseline bridge after a staging snapshot exists."
  @spec baseline(module(), String.t()) :: {:ok, map()} | {:error, atom()}
  def baseline(repo, snapshot_ref) when is_atom(repo) and is_binary(snapshot_ref) do
    with :ok <- ensure_admitted(),
         :ok <- validate_snapshot_ref(snapshot_ref) do
      map = load_map!()

      repo.transaction(fn ->
        _lock = SQL.query!(repo, "SELECT pg_advisory_xact_lock($1)", [@lock_id])
        before = classify_repo(repo, map)

        case before.classification do
          "prior" ->
            apply_bridge!(repo)
            insert_baseline_versions!(repo, baseline_versions(map))
            after_baseline = classify_repo(repo, map)

            if after_baseline.classification != "prior_baselined" do
              repo.rollback(:baseline_postcondition_failed)
            end

            result(after_baseline, snapshot_ref, true)

          "prior_baselined" ->
            result(before, snapshot_ref, false)

          "prior_partial" ->
            repo.rollback(:partial_lineage_forbidden)

          _other ->
            repo.rollback(:lineage_not_baselineable)
        end
      end)
      |> normalize_transaction()
    end
  end

  def baseline(_repo, _snapshot_ref), do: {:error, :invalid_baseline_request}

  @doc "Returns one bounded JSON result for the release operator command."
  @spec command!(module(), String.t(), String.t() | nil) :: String.t()
  def command!(repo, "check", _snapshot_ref) do
    case classify(repo) do
      {:ok, result} -> encode_result("checked", result)
      {:error, reason} -> raise "migration lineage check refused: #{bounded_reason(reason)}"
    end
  end

  def command!(repo, "apply", snapshot_ref) do
    case baseline(repo, snapshot_ref) do
      {:ok, result} -> encode_result("baselined", result)
      {:error, reason} -> raise "migration lineage baseline refused: #{bounded_reason(reason)}"
    end
  end

  def command!(_repo, _mode, _snapshot_ref),
    do: raise("migration lineage command mode is invalid")

  @doc "Loads the reviewed baseline map and its source digest."
  @spec map!() :: map()
  def map!, do: load_map!()

  defp classify_repo(repo, map) do
    versions = migration_versions(repo)
    baseline_versions = baseline_versions(map)
    prior? = subset?(map.data["prior_signature_versions"], versions)
    current? = Enum.any?(map.data["current_root_versions"], &MapSet.member?(versions, &1))
    baseline_count = Enum.count(baseline_versions, &MapSet.member?(versions, &1))

    fact_counts =
      fact_counts(repo, map.data, if(baseline_count == 0, do: :before, else: :after))

    bridge = bridge_state(repo)
    application_table_count = application_table_count(repo)

    classification =
      cond do
        application_table_count == 0 ->
          :empty

        prior? and baseline_count == 0 and bridge == :absent and fact_counts.missing == 0 ->
          :prior

        prior? and baseline_count == length(baseline_versions) and bridge == :complete and
            fact_counts.missing == 0 ->
          :prior_baselined

        prior? and (baseline_count > 0 or bridge != :absent) ->
          :prior_partial

        current? and not prior? ->
          :current

        true ->
          :unknown
      end

    %{
      schema: "openagents.migration-lineage-status.v1",
      classification: Atom.to_string(classification),
      lineage_id: map.data["lineage_id"],
      map_digest: map.digest,
      migration_count: MapSet.size(versions),
      baseline_entries_present: baseline_count,
      baseline_entries_required: length(baseline_versions),
      required_facts_present: fact_counts.present,
      required_facts_missing: fact_counts.missing,
      bridge_state: Atom.to_string(bridge)
    }
  end

  defp fact_counts(repo, map, phase) do
    phase_indexes =
      if phase == :before,
        do: map["pre_baseline_required_indexes"],
        else: []

    facts =
      Enum.map(map["required_tables"], &table_exists?(repo, &1)) ++
        Enum.flat_map(map["required_columns"], fn {table, columns} ->
          Enum.map(columns, &column_exists?(repo, table, &1))
        end) ++
        Enum.map(map["required_column_types"], fn {qualified_column, type} ->
          [table, column] = String.split(qualified_column, ".", parts: 2)
          column_type?(repo, table, column, type)
        end) ++
        Enum.map(map["required_constraints"], &constraint_exists?(repo, &1)) ++
        Enum.map(map["required_indexes"], &index_exists?(repo, &1)) ++
        Enum.map(phase_indexes, &index_exists?(repo, &1)) ++
        Enum.map(map["forbidden_constraints"], &(not constraint_exists?(repo, &1))) ++
        Enum.map(map["forbidden_tables"], &(not table_exists?(repo, &1)))

    present = Enum.count(facts, & &1)
    %{present: present, missing: length(facts) - present}
  end

  defp bridge_state(repo) do
    column? = column_exists?(repo, "users", "browser_key_hash")
    index? = index_exists?(repo, "users_browser_key_hash_index")

    case {column?, index?} do
      {false, false} -> :absent
      {true, true} -> :complete
      _partial -> :partial
    end
  end

  defp application_table_count(repo) do
    %{rows: [[count]]} =
      SQL.query!(repo, """
      SELECT count(*)
        FROM pg_catalog.pg_tables
       WHERE schemaname = current_schema()
         AND tablename <> 'schema_migrations'
      """)

    count
  end

  defp migration_versions(repo) do
    if table_exists?(repo, "schema_migrations") do
      %{rows: rows} =
        SQL.query!(repo, "SELECT version FROM schema_migrations ORDER BY version", [])

      rows |> Enum.map(fn [version] -> version end) |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp table_exists?(repo, table) do
    exists?(
      repo,
      "SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1",
      [table]
    )
  end

  defp column_exists?(repo, table, column) do
    exists?(
      repo,
      "SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
      [table, column]
    )
  end

  defp column_type?(repo, table, column, type) do
    exists?(
      repo,
      "SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2 AND udt_name = $3",
      [table, column, type]
    )
  end

  defp constraint_exists?(repo, constraint) do
    exists?(
      repo,
      "SELECT 1 FROM information_schema.table_constraints WHERE constraint_schema = current_schema() AND constraint_name = $1",
      [constraint]
    )
  end

  defp index_exists?(repo, index) do
    exists?(
      repo,
      "SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname = current_schema() AND indexname = $1",
      [index]
    )
  end

  defp exists?(repo, query, parameters) do
    case SQL.query!(repo, query, parameters) do
      %{num_rows: count} when count > 0 -> true
      _none -> false
    end
  end

  defp apply_bridge!(repo) do
    _column = SQL.query!(repo, "ALTER TABLE users ADD COLUMN browser_key_hash bytea", [])

    _index =
      SQL.query!(repo, """
      CREATE UNIQUE INDEX users_browser_key_hash_index
          ON users (browser_key_hash)
       WHERE browser_key_hash IS NOT NULL
      """)

    :ok
  end

  defp insert_baseline_versions!(repo, versions) do
    Enum.each(versions, fn version ->
      _result =
        SQL.query!(
          repo,
          "INSERT INTO schema_migrations (version, inserted_at) VALUES ($1, NOW()) ON CONFLICT (version) DO NOTHING",
          [version]
        )
    end)
  end

  defp baseline_versions(map) do
    Enum.map(map.data["baseline_entries"], & &1["current_version"])
  end

  defp subset?(required, actual) do
    Enum.all?(required, &MapSet.member?(actual, &1))
  end

  defp load_map! do
    path = :openagents |> :code.priv_dir() |> to_string() |> Path.join(@map_file)
    bytes = File.read!(path)
    data = Jason.decode!(bytes)

    if data["schema"] != "openagents.migration-lineage.v1" or
         data["lineage_id"] != "prior-2026-08-19" do
      raise "migration lineage map has an invalid identity"
    end

    %{data: data, digest: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end

  defp ensure_admitted do
    environment = Application.get_env(:openagents, :runtime_environment)
    staging_gate = Application.get_env(:openagents, :staging_gate, 0)

    if environment == :test or (environment == :staging and staging_gate >= 13) do
      :ok
    else
      {:error, :migration_lineage_not_admitted}
    end
  end

  defp validate_snapshot_ref(snapshot_ref) do
    if Regex.match?(@snapshot_pattern, snapshot_ref),
      do: :ok,
      else: {:error, :invalid_snapshot_reference}
  end

  defp result(classification, snapshot_ref, changed?) do
    classification
    |> Map.put(:snapshot_ref, snapshot_ref)
    |> Map.put(:changed, changed?)
  end

  defp normalize_transaction({:ok, result}), do: {:ok, result}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp encode_result(status, result) do
    result
    |> Map.put(:status, status)
    |> Jason.encode!()
  end

  defp bounded_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp bounded_reason(_reason), do: "lineage_operation_failed"
end
