defmodule OpenAgents.Tools.Embeddings do
  @moduledoc """
  Vector embeddings for the tool catalog, for cosine-similarity discovery.

  There are only a handful of tools, so the vectors live in a `persistent_term`
  cache keyed by the registry digest and cosine is computed in process — no
  pgvector, no per-turn index. The provider is the same embedding boundary the
  memory system uses.

  Everything degrades safely: if embeddings are disabled or the provider errors,
  `vectors/1` and `embed_query/1` return `nil`/`:error` and the Selector falls
  back to lexical scoring. A tool turn must never fail because embeddings are
  unavailable.
  """

  alias OpenAgents.Tools.Discovery.Doc
  alias OpenAgents.Tools.Snapshot

  require Logger

  @persistent_key {__MODULE__, :vectors}

  @doc "Whether embedding-backed discovery is switched on and configured."
  @spec enabled?() :: boolean()
  def enabled? do
    config = Application.get_env(:sarah, :tool_discovery, [])
    Keyword.get(config, :embeddings_enabled, false) == true and not is_nil(provider())
  end

  @doc """
  Compute and cache the tool vectors for this snapshot's digest. Safe to call at
  boot from a Task; returns `:ok` on success or when disabled, `:error` on a
  provider failure (leaving the cache empty so callers fall back to lexical).
  """
  @spec warm(Snapshot.t()) :: :ok | :error
  def warm(%Snapshot{digest: digest} = snapshot) do
    cond do
      not enabled?() -> :ok
      is_map(cached(digest)) -> :ok
      true -> build_and_cache(snapshot)
    end
  rescue
    error ->
      Logger.warning("tool_embeddings_warm_failed error=#{Exception.message(error)}")
      :error
  end

  @doc "Cached tool-name → vector map for a digest, or nil when unavailable."
  @spec vectors(String.t()) :: %{optional(String.t()) => [float()]} | nil
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

  @doc "Cosine similarity of two equal-length vectors; 0.0 on any mismatch."
  @spec cosine([float()], [float()]) :: float()
  def cosine(a, b) when is_list(a) and is_list(b) and length(a) == length(b) and a != [] do
    {dot, na, nb} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (:math.sqrt(na) * :math.sqrt(nb))
  end

  def cosine(_a, _b), do: 0.0

  # ── internal ───────────────────────────────────────────────────────────────

  defp build_and_cache(%Snapshot{digest: digest} = snapshot) do
    tools = Map.values(snapshot.tools)

    vectors =
      tools
      |> Enum.reduce_while(%{}, fn tool, acc ->
        case provider().embed(Doc.text(tool), embed_config()) do
          {:ok, vector} when is_list(vector) and vector != [] ->
            {:cont, Map.put(acc, tool.name, vector)}

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
          "tool_embeddings_warmed digest=#{binary_part(digest, 0, 12)} count=#{map_size(map)}"
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
    :sarah
    |> Application.get_env(:tool_discovery, [])
    |> Keyword.get(:provider)
  end

  defp embed_config do
    config = Application.get_env(:sarah, :tool_discovery, [])

    %{
      model_id: Keyword.get(config, :model_id, "text-embedding-3-small"),
      model_version: Keyword.get(config, :model_version, "2024-01"),
      dimensions: Keyword.get(config, :dimensions, 64)
    }
  end
end
