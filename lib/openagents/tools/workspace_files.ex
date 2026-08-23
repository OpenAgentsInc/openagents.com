defmodule OpenAgents.Tools.WorkspaceFiles do
  @moduledoc false

  alias OpenAgents.Tools.{ExecutionContext, Repository}

  @workspace_types ~w(repository_workspace computer_workspace)

  def resolve(%ExecutionContext{workspace: workspace}, path, access)
      when is_map(workspace) and access in [:read, :write] do
    with {:ok, root} <- workspace_root(workspace, access),
         {:ok, resolved} <- safe_path(root, path),
         :ok <- reject_symlinks(root, resolved) do
      {:ok, %{root: root, path: path, resolved: resolved, ref: workspace_ref(workspace, root)}}
    end
  end

  def resolve(_context, _path, _access), do: {:error, :workspace_required}

  def serialize(%{resolved: resolved}, operation),
    do: :global.trans({{__MODULE__, resolved}, self()}, operation)

  def digest(content) when is_binary(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  def atomic_write(%{resolved: resolved} = target, content) when is_binary(content) do
    parent = Path.dirname(resolved)

    with :ok <- File.mkdir_p(parent),
         :ok <- reject_symlinks(target.root, resolved),
         {:ok, snapshot} <- snapshot(target) do
      case rename_write(resolved, content) do
        :ok ->
          final_digest = digest(content)

          {:ok,
           %{
             "action" => if(snapshot.existed, do: "replaced", else: "created"),
             "bytes" => byte_size(content),
             "final_digest" => final_digest,
             "path" => target.path,
             "prior_digest" => snapshot.prior_digest,
             "snapshot_ref" => snapshot.ref,
             "workspace_ref" => target.ref,
             "effect_receipt" => receipt(target, final_digest)
           }}

        {:error, reason} ->
          File.rm_rf(snapshot.directory)
          {:error, reason}
      end
    end
  end

  def read_regular(%{resolved: resolved}) do
    case File.lstat(resolved) do
      {:ok, %File.Stat{type: :regular}} -> File.read(resolved)
      {:ok, %File.Stat{type: :directory}} -> {:error, :workspace_path_is_directory}
      {:ok, _stat} -> {:error, :workspace_path_not_regular}
      {:error, :enoent} -> {:error, :workspace_file_not_found}
      {:error, reason} -> {:error, {:workspace_read_failed, reason}}
    end
  end

  def exact_edits(original, edits) when is_binary(original) and is_list(edits) do
    with :ok <- validate_text(original),
         {:ok, ranges} <- edit_ranges(original, edits),
         :ok <- reject_overlaps(ranges) do
      updated =
        ranges
        |> Enum.sort_by(& &1.start, :desc)
        |> Enum.reduce(original, fn edit, content ->
          prefix = binary_part(content, 0, edit.start)
          suffix_start = edit.start + edit.length
          suffix = binary_part(content, suffix_start, byte_size(content) - suffix_start)
          prefix <> edit.new_text <> suffix
        end)

      {:ok, updated, length(ranges)}
    end
  end

  def exact_edits(_original, _edits), do: {:error, :invalid_edits}

  defp workspace_root(workspace, access) do
    type = fetch(workspace, "type", :type)
    root = fetch(workspace, "root", :root)
    canonical = fetch(workspace, "canonical", :canonical)
    read_only = fetch(workspace, "read_only", :read_only)

    cond do
      type not in @workspace_types -> {:error, :workspace_required}
      canonical != false -> {:error, :canonical_workspace_refused}
      access == :write and read_only != false -> {:error, :workspace_read_only}
      not is_binary(root) or Path.type(root) != :absolute -> {:error, :workspace_required}
      protected_root?(root) -> {:error, :canonical_workspace_refused}
      true -> {:ok, Path.expand(root)}
    end
  end

  defp protected_root?(root) do
    candidate = Path.expand(root)

    [Repository.source_dir(), Application.get_env(:openagents, :forge_data_dir)]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(fn protected ->
      protected = Path.expand(protected)

      candidate == protected or String.starts_with?(candidate, protected <> "/") or
        String.starts_with?(protected, candidate <> "/")
    end)
  end

  defp safe_path(root, path) when is_binary(path) and byte_size(path) <= 512 do
    cond do
      path == "" or Path.type(path) == :absolute or String.contains?(path, "\0") ->
        {:error, :invalid_workspace_path}

      path == ".openagents" or String.starts_with?(path, ".openagents/") ->
        {:error, :reserved_workspace_path}

      true ->
        expanded = Path.expand(path, root)

        if String.starts_with?(expanded, root <> "/"),
          do: {:ok, expanded},
          else: {:error, :workspace_path_escape}
    end
  end

  defp safe_path(_root, _path), do: {:error, :invalid_workspace_path}

  defp reject_symlinks(root, resolved) do
    relative = Path.relative_to(resolved, root)

    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :workspace_symlink_refused}}
        {:ok, _stat} -> {:cont, next}
        {:error, :enoent} -> {:halt, :ok}
        {:error, reason} -> {:halt, {:error, {:workspace_stat_failed, reason}}}
      end
    end)
    |> case do
      value when is_binary(value) -> :ok
      result -> result
    end
  end

  defp snapshot(%{resolved: resolved, root: workspace_root, path: path, ref: workspace_ref}) do
    id = Ecto.UUID.generate()

    with {:ok, root} <- snapshot_root(workspace_root),
         directory = Path.join(root, id),
         manifest_path = Path.join(directory, "manifest.json"),
         {:ok, prior} <- prior_content(resolved),
         :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700) do
      result =
        with :ok <- maybe_write_snapshot(directory, prior),
             :ok <-
               secure_write(
                 manifest_path,
                 Jason.encode!(%{
                   "existed" => prior != :missing,
                   "path" => path,
                   "prior_digest" => if(prior == :missing, do: nil, else: digest(prior)),
                   "workspace_ref" => workspace_ref
                 })
               ) do
          {:ok,
           %{
             directory: directory,
             existed: prior != :missing,
             prior_digest: if(prior == :missing, do: nil, else: digest(prior)),
             ref: "workspace-snapshot:" <> id
           }}
        end

      if match?({:error, _reason}, result), do: File.rm_rf(directory)
      result
    end
  end

  defp prior_content(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.read(path)
      {:ok, %File.Stat{type: :directory}} -> {:error, :workspace_path_is_directory}
      {:ok, _stat} -> {:error, :workspace_path_not_regular}
      {:error, :enoent} -> {:ok, :missing}
      {:error, reason} -> {:error, {:workspace_read_failed, reason}}
    end
  end

  defp maybe_write_snapshot(_directory, :missing), do: :ok

  defp maybe_write_snapshot(directory, content),
    do: secure_write(Path.join(directory, "content"), content)

  defp secure_write(path, content) do
    with :ok <- File.write(path, content, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp rename_write(path, content) do
    temporary = path <> ".openagents-" <> Ecto.UUID.generate() <> ".tmp"

    try do
      with :ok <- File.write(temporary, content, [:binary, :exclusive]),
           :ok <- File.rename(temporary, path) do
        :ok
      end
    after
      File.rm(temporary)
    end
  end

  defp workspace_ref(workspace, root) do
    fetch(workspace, "workspace_ref", :workspace_ref) ||
      "workspace:" <> (digest(root) |> binary_part(0, 16))
  end

  defp snapshot_root(workspace_root) do
    root =
      Application.get_env(
        :openagents,
        :workspace_snapshot_dir,
        Path.join(System.tmp_dir!(), "openagents-workspace-snapshots")
      )

    cond do
      not is_binary(root) or Path.type(root) != :absolute ->
        {:error, :workspace_snapshot_root_invalid}

      Path.expand(root) == Path.expand(workspace_root) or
          String.starts_with?(Path.expand(root), Path.expand(workspace_root) <> "/") ->
        {:error, :workspace_snapshot_root_invalid}

      true ->
        {:ok, Path.expand(root)}
    end
  end

  defp fetch(map, string_key, atom_key) do
    if Map.has_key?(map, string_key), do: Map.get(map, string_key), else: Map.get(map, atom_key)
  end

  defp receipt(target, final_digest) do
    identity = digest(target.ref <> "\0" <> target.path) |> binary_part(0, 24)
    "workspace-file:#{identity}:#{final_digest}"
  end

  defp validate_text(content) do
    if String.valid?(content), do: :ok, else: {:error, :workspace_invalid_encoding}
  end

  defp edit_ranges(original, edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"old_text" => old_text, "new_text" => new_text}, index}, {:ok, ranges}
      when is_binary(old_text) and is_binary(new_text) ->
        with :ok <- validate_edit_text(old_text, new_text),
             {:ok, start} <- unique_match(original, old_text) do
          range = %{start: start, length: byte_size(old_text), new_text: new_text, index: index}
          {:cont, {:ok, [range | ranges]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _, _acc ->
        {:halt, {:error, :invalid_edits}}
    end)
  end

  defp validate_edit_text(old_text, new_text) do
    cond do
      old_text == "" ->
        {:error, :empty_match_string}

      old_text == new_text ->
        {:error, :edit_is_noop}

      not String.valid?(old_text) or not String.valid?(new_text) ->
        {:error, :workspace_invalid_encoding}

      true ->
        :ok
    end
  end

  defp unique_match(content, old_text) do
    case :binary.matches(content, old_text) do
      [] -> {:error, :no_match}
      [{start, _length}] -> {:ok, start}
      _matches -> {:error, :ambiguous_match}
    end
  end

  defp reject_overlaps(ranges) do
    ranges
    |> Enum.sort_by(& &1.start)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [left, right] -> left.start + left.length > right.start end)
    |> case do
      nil -> :ok
      _pair -> {:error, :overlapping_edits}
    end
  end
end
