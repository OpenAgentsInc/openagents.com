defmodule OpenAgentsWeb.OG.Limiter do
  @moduledoc """
  Bounds how many card rasterizations run at once.

  Rasterization is the only expensive step in the card pipeline, and misses
  are rare thanks to immutable caching — but a burst of cold requests (a link
  going viral, a cache flush) must not fan out into unbounded port processes.
  The counter lives in a named public ETS table so `update_counter/4` gives us
  an atomic increment-and-check without a process bottleneck: acquirers that
  find themselves over budget release immediately and report `:busy`, which
  callers turn into the static fallback card.
  """

  @table :og_rasterizer_limiter
  @key :active

  @doc """
  Takes one slot, or reports `:busy` when `max` rasterizations are already
  running. Always pair a successful acquire with `release/0`.
  """
  @spec acquire(pos_integer()) :: :ok | :busy
  def acquire(max \\ max_concurrent()) do
    ensure_table!()

    case :ets.update_counter(@table, @key, {2, 1}, {@key, 0}) do
      current when current <= max ->
        :ok

      _over_budget ->
        release()
        :busy
    end
  end

  @doc "Returns one slot. Safe to call even when no slot was taken."
  def release do
    ensure_table!()
    :ets.update_counter(@table, @key, {2, -1}, {@key, 0})
    :ok
  end

  defp ensure_table! do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp max_concurrent, do: Application.get_env(:openagents, :og_max_concurrent, 4)
end
