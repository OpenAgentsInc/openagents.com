defmodule OpenAgents.Forge.WAL.Local do
  @moduledoc """
  Filesystem adapter for `OpenAgents.Forge.WAL` — the development and test backend.

  Layout under the durable base directory
  (`Application.get_env(:openagents, :forge_wal_dir)`).

      <base>/<repo>/index.json
      <base>/<repo>/entries/<key>

  The generation is an integer stored inside `index.json` as `"generation"`;
  `read_index/1` strips it from the returned index and hands it back as the
  opaque generation token. CAS is made atomic by serializing every
  `cas_index/3` for a repo through `:global.trans/2` on a per-repo lock and
  writing the index via a temp file plus `File.rename/2`, so readers never
  observe a partial document and concurrent writers never both win.
  """

  @behaviour OpenAgents.Forge.WAL

  alias OpenAgents.Forge.WAL

  @impl WAL
  def read_index(repo) do
    case File.read(index_path(repo)) do
      {:ok, raw} -> decode_index(raw)
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl WAL
  def cas_index(repo, expected, index) when is_map(index) do
    :global.trans({{:forge_wal, repo}, self()}, fn ->
      do_cas(repo, expected, index)
    end)
  end

  @impl WAL
  def put_entry(repo, seq, payload) when is_integer(seq) and seq >= 0 and is_binary(payload) do
    key = WAL.entry_key(seq, payload)
    path = Path.join(repo_dir(repo), key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, payload) do
      {:ok, key}
    end
  end

  @impl WAL
  def put_object(repo, object_key, payload) when is_binary(payload) do
    path = Path.join(repo_dir(repo), object_key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, payload) do
      {:ok, object_key}
    end
  end

  @impl WAL
  def get_entry(repo, object_key) do
    case File.read(Path.join(repo_dir(repo), object_key)) do
      {:ok, payload} -> {:ok, payload}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Internal

  defp do_cas(repo, :none, index) do
    if File.exists?(index_path(repo)) do
      {:error, :cas_conflict}
    else
      write_index(repo, 1, index)
    end
  end

  defp do_cas(repo, expected, index) when is_integer(expected) do
    case read_index(repo) do
      {:ok, ^expected, _current} -> write_index(repo, expected + 1, index)
      {:ok, _other, _current} -> {:error, :cas_conflict}
      {:error, :not_found} -> {:error, :cas_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_cas(_repo, expected, _index), do: {:error, {:invalid_generation, expected}}

  defp write_index(repo, generation, index) do
    path = index_path(repo)
    temp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with {:ok, encoded} <- Jason.encode(Map.put(index, "generation", generation)),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp, encoded),
         :ok <- File.rename(temp, path) do
      {:ok, generation}
    end
  end

  defp decode_index(raw) do
    case Jason.decode(raw) do
      {:ok, %{"generation" => generation} = index} when is_integer(generation) ->
        {:ok, generation, Map.delete(index, "generation")}

      {:ok, other} ->
        {:error, {:invalid_index, other}}

      {:error, reason} ->
        {:error, {:invalid_index, reason}}
    end
  end

  defp index_path(repo), do: Path.join(repo_dir(repo), "index.json")

  defp repo_dir(repo), do: Path.join(base_dir(), repo)

  defp base_dir do
    Application.get_env(:openagents, :forge_wal_dir) ||
      "/var/lib/openagents/forge-wal"
  end
end
