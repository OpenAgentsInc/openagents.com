defmodule OpenAgents.VocabularyTest do
  @moduledoc """
  CANON-002. Proves the `machine` exemption ledger against the live database.

  The population comes from `information_schema` and `pg_catalog`, not from a
  list someone maintained beside the ledger, so a `machine`-named table,
  column, constraint, or index added by any migration fails here until it is
  recorded in `OpenAgents.Vocabulary` with a reason.
  """
  use OpenAgents.DataCase, async: true

  alias OpenAgents.Vocabulary

  @pattern "%machine%"

  test "every machine-named table in the database is on the ledger" do
    assert live_tables() == Enum.sort(Vocabulary.tables())
  end

  test "every machine-named column in the database is on the ledger" do
    assert live_columns() == Enum.sort(Vocabulary.columns())
  end

  test "every machine-named constraint in the database is on the ledger" do
    assert live_constraints() == Enum.sort(Vocabulary.constraints())
  end

  test "every machine-named index in the database is on the ledger" do
    assert live_indexes() == Enum.sort(Vocabulary.indexes())
  end

  test "the ledger claims nothing the database does not have" do
    live = MapSet.new(live_tables())

    for table <- Vocabulary.tables() do
      assert MapSet.member?(live, table), "ledger names a table that does not exist: #{table}"
    end

    tables = MapSet.new(live_tables() ++ table_names())

    for {table, name} <- Vocabulary.columns() ++ Vocabulary.constraints() ++ Vocabulary.indexes() do
      assert MapSet.member?(tables, table),
             "ledger entry #{name} names a table that does not exist: #{table}"
    end
  end

  defp live_tables do
    """
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name LIKE $1
    """
    |> rows([@pattern])
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  defp live_columns do
    """
    SELECT table_name, column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name LIKE $1
    """
    |> rows([@pattern])
    |> pairs()
  end

  defp live_constraints do
    """
    SELECT c.conrelid::regclass::text, c.conname
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'public' AND c.conname LIKE $1
    """
    |> rows([@pattern])
    |> pairs()
  end

  defp live_indexes do
    """
    SELECT tablename, indexname FROM pg_indexes
    WHERE schemaname = 'public' AND indexname LIKE $1
    """
    |> rows([@pattern])
    |> pairs()
  end

  defp table_names do
    """
    SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'
    """
    |> rows([])
    |> Enum.map(&hd/1)
  end

  defp rows(sql, params) do
    %Postgrex.Result{rows: rows} = Ecto.Adapters.SQL.query!(OpenAgents.Repo, sql, params)
    rows
  end

  defp pairs(rows), do: rows |> Enum.map(fn [a, b] -> {a, b} end) |> Enum.sort()
end
