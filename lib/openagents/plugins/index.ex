defmodule OpenAgents.Plugins.Index do
  @moduledoc """
  A typed index of validated plugin manifests.

  The index accepts a source of `{repository, release, raw_manifest}` entries
  and surfaces only those whose manifests validate. It supports listing and
  exact-name lookup, leaving semantic selection to callers.
  """

  require Logger

  alias OpenAgents.Plugins.Embeddings
  alias OpenAgents.Plugins.Manifest

  defmodule Entry do
    @moduledoc "One indexed, validated plugin release."
    defstruct [:repository, :release, :manifest, :score]

    @type t :: %__MODULE__{
            repository: String.t(),
            release: String.t(),
            manifest: map(),
            score: float() | nil
          }
  end

  @doc "List validated plugin entries from the configured or provided source."
  @spec list(keyword()) :: [Entry.t()]
  def list(opts \\ []) do
    source = Keyword.get(opts, :source, default_source())

    source
    |> fetch()
    |> Enum.reduce([], fn entry, acc ->
      case validate_entry(entry) do
        {:ok, validated} ->
          [validated | acc]

        {:error, %Manifest.ValidationError{} = error} ->
          Logger.warning(
            "plugin_manifest_invalid repository=#{entry.repository} release=#{entry.release} field=#{error.field}"
          )

          acc
      end
    end)
    |> Enum.reverse()
  end

  @doc "Look up one validated manifest by exact plugin name."
  @spec get(String.t(), keyword()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get(name, opts \\ []) when is_binary(name) do
    list(opts)
    |> Enum.find(fn %Entry{manifest: manifest} -> manifest["name"] == name end)
    |> case do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, :not_found}
    end
  end

  @doc "Render an index entry as a JSON-friendly map."
  @spec to_map(Entry.t()) :: map()
  def to_map(%Entry{repository: repository, release: release, manifest: manifest, score: score}) do
    base = %{
      "repository" => repository,
      "release" => release,
      "manifest" => manifest
    }

    if is_number(score), do: Map.put(base, "score", score), else: base
  end

  @doc """
  Search plugin manifests for `query` and return `{:ok, [Entry.t()]}`. When
  embeddings are enabled and available, results are sorted by cosine similarity
  and each entry has its `score` set; otherwise the unranked candidate list is
  returned for the caller to choose from. The call never raises because of a
  provider failure.
  """
  @spec search(String.t(), keyword()) :: {:ok, [Entry.t()]}
  def search(query, opts \\ []) when is_binary(query) do
    candidates = list(opts)
    top_k = Keyword.get(opts, :top_k, default_top_k())

    with true <- query != "" and Embeddings.enabled?(),
         {:ok, query_vector} <- Embeddings.embed_query(query),
         digest <- Embeddings.digest(candidates),
         vectors <- Embeddings.vectors(digest) || warm_and_vectors(candidates),
         true <- is_map(vectors) do
      ranked =
        candidates
        |> Enum.map(fn entry ->
          vector = Map.get(vectors, entry, [])
          score = Embeddings.cosine(query_vector, vector)
          %{entry | score: score}
        end)
        |> Enum.sort_by(fn entry -> {-entry.score, entry.manifest["name"]} end)
        |> Enum.take(top_k)

      {:ok, ranked}
    else
      _ -> {:ok, candidates}
    end
  end

  defp warm_and_vectors(candidates) do
    case Embeddings.warm(candidates) do
      :ok -> Embeddings.vectors(Embeddings.digest(candidates))
      :error -> nil
    end
  end

  defp default_top_k do
    :openagents
    |> Application.get_env(:plugin_discovery, [])
    |> Keyword.get(:top_k, 12)
  end

  defp fetch(module) when is_atom(module), do: module.entries()

  defp fetch(entries) when is_list(entries) do
    entries
    |> Enum.map(&to_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp to_entry(%{repository: repository, release: release, raw_manifest: raw_manifest})
       when is_binary(repository) and is_binary(release) and is_map(raw_manifest) do
    %Entry{repository: repository, release: release, manifest: raw_manifest}
  end

  defp to_entry(%Entry{} = entry), do: entry

  defp to_entry(_invalid) do
    Logger.warning("plugin_index_malformed_entry")
    nil
  end

  defp validate_entry(%Entry{manifest: raw_manifest} = entry) do
    case Manifest.validate(raw_manifest) do
      {:ok, manifest} -> {:ok, %Entry{entry | manifest: manifest}}
      {:error, %Manifest.ValidationError{} = error} -> {:error, error}
    end
  end

  defp default_source do
    Application.get_env(:openagents, OpenAgents.Plugins.Index,
      source: OpenAgents.Plugins.ForgeSource
    )[
      :source
    ]
  end
end
