defmodule OpenAgents.Plugins.Embeddings do
  @moduledoc """
  Vector embeddings for the plugin registry, for cosine-similarity discovery.

  There are only a handful of plugins, so the vectors live in a `persistent_term`
  cache keyed by a digest over the indexed manifest set and cosine is computed in
  process. The provider is the same embedding boundary the memory and tool
  discovery systems use.

  If embeddings are disabled, unconfigured, or the provider errors, `warm/1` and
  `embed_query/1` return `:ok`/`:error` and search falls back to the unranked
  candidate list. A plugin search must never fail because the embedding provider
  is down.
  """

  alias OpenAgents.Plugins.Discovery.Doc
  alias OpenAgents.Plugins.Index
  alias OpenAgents.Provenance.Canonical

  require Logger

  @persistent_key {__MODULE__, :vectors}

  @doc "Whether embedding-backed plugin discovery is switched on and configured."
  @spec enabled?() :: boolean()
  def enabled? do
    config = Application.get_env(:openagents, :plugin_discovery, [])
    Keyword.get(config, :embeddings_enabled, false) == true and not is_nil(provider())
  end

  @doc """
  Compute and cache the plugin vectors for the provided entries.

  Safe to call repeatedly; returns `:ok` when disabled, already cached, or
  successful, and `:error` on a provider failure (leaving the cache empty so
  callers fall back to the unranked candidate list).
  """
  @spec warm([Index.Entry.t()]) :: :ok | :error
  def warm(entries) when is_list(entries) do
    cond do
      not enabled?() -> :ok
      is_map(cached(digest(entries))) -> :ok
      true -> build_and_cache(entries)
    end
  rescue
    error ->
      Logger.warning(
        "plugin_embeddings_warm_failed code=#{OpenAgents.OperationalLog.code(error)}"
      )

      :error
  end

  @doc "Cached plugin entry → vector map for a digest, or nil when unavailable."
  @spec vectors(String.t()) :: %{optional(Index.Entry.t()) => [float()]} | nil
  def vectors(digest) when is_binary(digest), do: cached(digest)
  def vectors(_digest), do: nil

  @doc "Embed a query string, or `:error` when embeddings are unavailable."
  @spec embed_query(String.t()) :: {:ok, [float()]} | :error
  def embed_query(text) when is_binary(text) and text != "" do
    if enabled?() do
      case provider().embed(text, embed_config()) do
        {:ok, vector} when is_list(vector) and vector != [] -> {:ok, vector}
        _other -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  def embed_query(_text), do: :error

  @doc false
  @spec digest([Index.Entry.t()]) :: String.t()
  def digest(entries) when is_list(entries) do
    entries
    |> Enum.sort_by(&{&1.repository, &1.release, &1.manifest["name"]})
    |> Enum.map(fn %Index.Entry{} = entry ->
      %{
        "repository" => entry.repository,
        "release" => entry.release,
        "manifest" => entry.manifest
      }
    end)
    |> then(&Canonical.digest!/1)
  end

  defdelegate cosine(a, b), to: OpenAgents.Tools.Embeddings

  # ── internal ───────────────────────────────────────────────────────────────

  defp build_and_cache(entries) do
    digest = digest(entries)

    vectors =
      entries
      |> Enum.reduce_while(%{}, fn entry, acc ->
        case provider().embed(Doc.text(entry.manifest), embed_config()) do
          {:ok, vector} when is_list(vector) and vector != [] ->
            {:cont, Map.put(acc, entry, vector)}

          _other ->
            {:halt, :error}
        end
      end)

    case vectors do
      :error ->
        :error

      map when map_size(map) > 0 ->
        :persistent_term.put(@persistent_key, {digest, map})

        Logger.info(
          "plugin_embeddings_warmed digest=#{binary_part(digest, 0, 12)} count=#{map_size(map)}"
        )

        :ok

      _empty ->
        :ok
    end
  end

  defp cached(digest) do
    case :persistent_term.get(@persistent_key, nil) do
      {^digest, map} -> map
      _absent_or_stale -> nil
    end
  end

  defp provider do
    :openagents
    |> Application.get_env(:plugin_discovery, [])
    |> Keyword.get(:provider)
  end

  defp embed_config do
    config = Application.get_env(:openagents, :plugin_discovery, [])

    %{
      model_id: Keyword.get(config, :model_id, "text-embedding-3-small"),
      model_version: Keyword.get(config, :model_version, "2024-01"),
      dimensions: Keyword.get(config, :dimensions, 64)
    }
  end
end
