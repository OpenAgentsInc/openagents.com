defmodule OpenAgents.Forge.WAL do
  @moduledoc """
  Write-ahead log for OpenAgents.Forge git repositories.

  The WAL in object storage is the source of truth for git refs; node disks
  are only a cache. Every push appends one immutable entry object (the packed
  objects plus ref updates) and then advances a single per-repo index document
  through a compare-and-swap on the storage generation. Because the index CAS
  serializes all pushes, two nodes can never both believe they advanced the
  same ref — the loser sees `:cas_conflict`, refetches, and retries.

  The index is a JSON document:

      %{
        "version" => 1,
        "entries" => [
          %{
            "seq" => 0,
            "object" => "entries/00000000-<sha256 prefix>",
            "refs" => %{"refs/heads/main" => "<sha>"},
            "principal" => "...",
            "pushed_at" => "2026-08-18T00:00:00Z"
          }
        ],
        "refs" => %{"refs/heads/main" => "<sha>"}
      }

  Adapters implement the storage behaviour. The configured adapter comes from
  `Application.get_env(:openagents, :forge_wal_adapter)` and defaults to
  `OpenAgents.Forge.WAL.Local`; production uses `OpenAgents.Forge.WAL.Gcs`.
  """

  @typedoc "Repository name: `[a-z0-9][a-z0-9_-]*`, no `.git` suffix, no slashes."
  @type repo :: String.t()

  @typedoc "Opaque adapter-specific generation (integer for Local, GCS generation string for GCS)."
  @type generation :: term()

  @typedoc "Decoded JSON index document."
  @type index :: map()

  @callback read_index(repo) :: {:ok, generation, index} | {:error, :not_found} | {:error, term}
  @callback cas_index(repo, expected :: generation | :none, index) ::
              {:ok, generation} | {:error, :cas_conflict} | {:error, term}
  @callback put_entry(repo, seq :: non_neg_integer(), payload :: binary()) ::
              {:ok, object_key :: String.t()} | {:error, term}
  @callback get_entry(repo, object_key :: String.t()) :: {:ok, binary()} | {:error, term}
  @callback put_object(repo, object_key :: String.t(), payload :: binary()) ::
              {:ok, String.t()} | {:error, term}

  @repo_pattern ~r/^[a-z0-9][a-z0-9_-]*$/
  @entry_key_pattern ~r/^entries\/[0-9]{8}-[0-9a-f]{12}$/
  @artifact_key_pattern ~r/^artifacts\/[0-9a-f]{7,40}\.tar$/

  ## Dispatcher

  @doc """
  Read the current index for `repo` through the configured adapter.

  Returns `{:ok, generation, index}` where `generation` is the opaque token
  `cas_index/3` must be given to advance the index.
  """
  @spec read_index(repo) :: {:ok, generation, index} | {:error, :not_found} | {:error, term}
  def read_index(repo) do
    with :ok <- validate_repo(repo), do: adapter().read_index(repo)
  end

  @doc """
  Compare-and-swap the index for `repo`.

  `expected` is the generation returned by the last `read_index/1`, or `:none`
  to create the index only if it does not exist yet (first push). Returns the
  new generation on success and `{:error, :cas_conflict}` when the stored
  index moved under the caller.
  """
  @spec cas_index(repo, generation | :none, index) ::
          {:ok, generation} | {:error, :cas_conflict} | {:error, term}
  def cas_index(repo, expected, index) when is_map(index) do
    with :ok <- validate_repo(repo), do: adapter().cas_index(repo, expected, index)
  end

  @doc """
  Store one immutable WAL entry payload for `repo` at sequence `seq`.

  Returns the object key to record in the index entry. Idempotent: the key is
  derived from the sequence number and the payload hash, so re-putting the
  same payload yields the same key.
  """
  @spec put_entry(repo, non_neg_integer(), binary()) :: {:ok, String.t()} | {:error, term}
  def put_entry(repo, seq, payload) when is_integer(seq) and seq >= 0 and is_binary(payload) do
    with :ok <- validate_repo(repo), do: adapter().put_entry(repo, seq, payload)
  end

  @doc """
  Fetch a previously stored WAL entry payload for `repo` by its object key.
  """
  @spec get_entry(repo, String.t()) :: {:ok, binary()} | {:error, term}
  def get_entry(repo, object_key) when is_binary(object_key) do
    with :ok <- validate_repo(repo),
         :ok <- validate_entry_key(object_key) do
      adapter().get_entry(repo, object_key)
    end
  end

  @doc """
  Store a named artifact blob alongside the WAL (P6, #123): built beam tars
  land here so a replaced node — whose local artifact cache is empty — can
  still boot-converge to the promoted target. Cache, not authority: the
  same content is re-buildable from the pushed commit.
  """
  @spec put_artifact(repo, String.t(), binary()) :: {:ok, String.t()} | {:error, term}
  def put_artifact(repo, sha, payload) when is_binary(sha) and is_binary(payload) do
    key = artifact_key(sha)

    with :ok <- validate_repo(repo),
         :ok <- validate_artifact_key(key) do
      adapter().put_object(repo, key, payload)
    end
  end

  @doc "Fetch an artifact blob by sha (see `put_artifact/3`)."
  @spec get_artifact(repo, String.t()) :: {:ok, binary()} | {:error, term}
  def get_artifact(repo, sha) when is_binary(sha) do
    key = artifact_key(sha)

    with :ok <- validate_repo(repo),
         :ok <- validate_artifact_key(key) do
      adapter().get_entry(repo, key)
    end
  end

  @doc false
  def artifact_key(sha), do: "artifacts/" <> sha <> ".tar"

  ## Pure helpers

  @doc """
  A fresh, empty index document.
  """
  @spec new_index() :: index
  def new_index do
    %{"version" => 1, "entries" => [], "refs" => %{}}
  end

  @doc """
  Append `entry` to the index and replace the top-level `"refs"` with the
  entry's post-state refs.

  The entry must carry `"seq"`, `"object"`, `"refs"`, `"principal"`, and
  `"pushed_at"`. Raises `ArgumentError` if `"seq"` is not the next sequence
  number (`length(entries)`) — an out-of-order append is a caller bug, never
  something to write into the log.
  """
  @spec append_entry(index, map()) :: index
  def append_entry(%{"entries" => entries} = index, %{"seq" => seq} = entry)
      when is_list(entries) do
    expected = length(entries)

    unless seq == expected do
      raise ArgumentError,
            "WAL entry seq #{inspect(seq)} does not match next seq #{expected}"
    end

    unless is_map(entry["refs"]) do
      raise ArgumentError, "WAL entry must carry a \"refs\" map, got: #{inspect(entry["refs"])}"
    end

    index
    |> Map.put("entries", entries ++ [entry])
    |> Map.put("refs", entry["refs"])
  end

  @doc """
  The next sequence number to append to `index`.
  """
  @spec next_seq(index) :: non_neg_integer()
  def next_seq(%{"entries" => entries}) when is_list(entries), do: length(entries)

  @doc """
  The current ref map (`ref name => sha`) of `index`.
  """
  @spec refs(index) :: map()
  def refs(index), do: Map.get(index, "refs", %{})

  @doc """
  The ordered entry list of `index`.
  """
  @spec entries(index) :: [map()]
  def entries(index), do: Map.get(index, "entries", [])

  @doc """
  The canonical object key for the entry at `seq` with `payload`:
  `entries/<zero-padded seq>-<first 12 hex chars of sha256(payload)>`.
  """
  @spec entry_key(non_neg_integer(), binary()) :: String.t()
  def entry_key(seq, payload) when is_integer(seq) and seq >= 0 and is_binary(payload) do
    digest =
      :crypto.hash(:sha256, payload)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "entries/" <> String.pad_leading(Integer.to_string(seq), 8, "0") <> "-" <> digest
  end

  @doc """
  Validate a repository name (`[a-z0-9][a-z0-9_-]*`).
  """
  @spec validate_repo(term()) :: :ok | {:error, :invalid_repo}
  def validate_repo(repo) when is_binary(repo) do
    if Regex.match?(@repo_pattern, repo), do: :ok, else: {:error, :invalid_repo}
  end

  def validate_repo(_repo), do: {:error, :invalid_repo}

  defp validate_entry_key(object_key) do
    if Regex.match?(@entry_key_pattern, object_key) or
         Regex.match?(@artifact_key_pattern, object_key) do
      :ok
    else
      {:error, :invalid_object_key}
    end
  end

  defp validate_artifact_key(object_key) do
    if Regex.match?(@artifact_key_pattern, object_key) do
      :ok
    else
      {:error, :invalid_object_key}
    end
  end

  defp adapter do
    Application.get_env(:openagents, :forge_wal_adapter, OpenAgents.Forge.WAL.Local)
  end
end
