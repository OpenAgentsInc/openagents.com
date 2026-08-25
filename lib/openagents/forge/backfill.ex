defmodule OpenAgents.Forge.Backfill do
  @moduledoc """
  Import the history that predates a repository's seed into that repository's
  own write-ahead log.

  A repository seeded from a shallow fetch records a truthful boundary: the
  seed commit's parents were never fetched, so they were never written to the
  log, and `REPOSITORY-003`'s replay reproduces a grafted history from seq 0
  exactly as recorded. Every ref tip resolves and every clone succeeds, so
  nothing tip-shaped reports a problem. What is missing is everything behind
  the seed.

  Where a mirror holds that history and the log does not, the repository's own
  authority holds less than its copy does, and `EXIT-003`'s claim that the
  forge is the authority is weaker than it reads. This closes that gap the only
  way an append-only log can: by writing the missing objects into the log.

  The bundle is read once, at an operator's instruction, and appended as an
  ordinary `git_bundle` entry that carries the ref map unchanged and an empty
  shallow boundary set — the same entry shape `OpenAgents.Repositories.Importer`
  writes at seq 0, which is why replay needs no new case to apply it. The
  authority boundary is unchanged after it: a mirror supplied bytes on this one
  occasion, the log now holds them, and no read path consults a mirror.

  ## The entry is proven before it is written

  An append-only log cannot retract a bad entry. So the bundle is materialized
  against a throwaway repository that shares the current projection's objects,
  and the import refuses to touch the log unless that union can then be walked
  the way `git upload-pack` walks it — the same check
  `OpenAgents.Forge.Sync` uses to decide a projection is servable. A bundle
  that would leave the repository grafted, or that closes no boundary at all,
  is rejected while the log is still untouched.
  """

  alias OpenAgents.Forge.{Repos, Sync, WAL}

  require Logger

  @doc """
  Append `bundle_path` to `storage_key`'s log as a history import.

  Returns `{:ok, summary}` with the sequence written and the boundary commits
  the import closed, or `{:error, reason}` with the log unchanged.

  `principal` records who authorized the import, and is written to the entry
  the same way a push records its pusher.
  """
  @spec import_history(String.t(), String.t(), String.t()) ::
          {:ok, %{seq: non_neg_integer(), closed: [String.t()]}} | {:error, term()}
  def import_history(storage_key, bundle_path, principal)
      when is_binary(storage_key) and is_binary(bundle_path) and is_binary(principal) do
    with :ok <- validate_principal(principal),
         {:ok, generation, index} <- WAL.read_index(storage_key),
         projection = Repos.bare_path(storage_key),
         {:ok, closed} <- prove_bundle(projection, bundle_path),
         seq = WAL.next_seq(index),
         {:ok, object} <- WAL.put_entry_file(storage_key, seq, bundle_path) do
      entry = %{
        "seq" => seq,
        "object" => object,
        "format" => "git_bundle",
        "refs" => WAL.refs(index),
        "shallow" => [],
        "principal" => principal,
        "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      case WAL.cas_index(storage_key, generation, WAL.append_entry(index, entry)) do
        {:ok, _generation} ->
          Logger.info(
            "forge_backfill_imported repo=#{storage_key} seq=#{seq} closed=#{length(closed)}"
          )

          Sync.ensure_fresh(storage_key)
          {:ok, %{seq: seq, closed: closed}}

        {:error, reason} ->
          {:error, {:cas_failed, reason}}
      end
    end
  end

  # The boundary this import must close: the commits the projection holds whose
  # parents it does not. Derived from the objects on disk rather than from what
  # an entry recorded, because a commit whose parent is absent *is* a boundary
  # whatever the log says — the same derivation `OpenAgents.Forge.Sync` uses.
  @doc """
  The commits `storage_key`'s projection holds whose parents it does not.

  An empty list means the projection is already complete and an import has
  nothing to close.
  """
  @spec open_boundaries(String.t()) :: [String.t()]
  def open_boundaries(storage_key) do
    storage_key |> Repos.bare_path() |> boundaries_at()
  end

  defp boundaries_at(path) do
    case Repos.git(path, ["rev-list", "--all", "--max-parents=0"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{40}\z/, &1))
        |> Enum.filter(&grafted?(path, &1))

      {_output, _status} ->
        []
    end
  end

  # A root commit reported by `--max-parents=0` is either a genuine root or a
  # graft boundary, and the two are told apart by the commit object itself:
  # the object records its parents whether or not the repository holds them.
  defp grafted?(path, sha), do: parents_of(path, sha) != []

  # The parents a commit object records, which is not the same question as the
  # parents a repository holds: the object is immutable and names them whether
  # or not they were ever fetched.
  defp parents_of(path, sha) do
    case Repos.git(path, ["cat-file", "commit", sha]) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.take_while(&(&1 != ""))
        |> Enum.filter(&String.starts_with?(&1, "parent "))
        |> Enum.map(&(&1 |> String.replace_prefix("parent ", "") |> String.trim()))

      {_output, _status} ->
        []
    end
  end

  defp prove_bundle(projection, bundle_path) do
    cond do
      not File.dir?(projection) ->
        {:error, :projection_absent}

      not match?({:ok, %File.Stat{type: :regular}}, File.stat(bundle_path)) ->
        {:error, :bundle_unreadable}

      true ->
        boundaries = boundaries_at(projection)

        if boundaries == [] do
          {:error, :no_open_boundary}
        else
          prove_against_scratch(projection, bundle_path, boundaries)
        end
    end
  end

  # Shares the projection's objects through `objects/info/alternates` rather
  # than copying them, so proving a large repository costs the bundle's own
  # size and nothing more. Nothing here writes to the projection: an alternate
  # is read-only to the borrower, and every new object lands in the scratch
  # directory.
  defp prove_against_scratch(projection, bundle_path, boundaries) do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "openagents-backfill-#{System.unique_integer([:positive, :monotonic])}.git"
      )

    try do
      with :ok <- init_scratch(scratch, projection),
           :ok <- copy_refs(projection, scratch),
           {_output, 0} <- Repos.git(scratch, ["bundle", "unbundle", bundle_path]) do
        # The import claims the boundaries are closed, so prove the walk with
        # no graft in place at all rather than with the old one still excusing
        # it.
        File.rm(Path.join(scratch, "shallow"))

        # Name what must be true rather than inferring it from an exit status.
        # A repository with no refs walks clean, so a walk alone would pass
        # vacuously on a scratch copy that never received them; requiring each
        # boundary's recorded parents to resolve cannot.
        unresolved =
          boundaries
          |> Enum.flat_map(&parents_of(projection, &1))
          |> Enum.uniq()
          |> Enum.reject(&match?({_output, 0}, Repos.git(scratch, ["cat-file", "-e", &1])))

        cond do
          unresolved != [] ->
            {:error, {:still_grafted, unresolved}}

          not match?(
            {_output, 0},
            Repos.git(scratch, ["rev-list", "--objects", "--quiet", "--all"])
          ) ->
            {:error, {:unwalkable, boundaries}}

          true ->
            {:ok, boundaries}
        end
      else
        {:error, reason} -> {:error, reason}
        {_output, _status} -> {:error, :bundle_unreadable}
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp init_scratch(scratch, projection) do
    case Repos.git(scratch, ["init", "--bare", "--quiet", scratch]) do
      {_output, 0} ->
        alternates = Path.join([scratch, "objects", "info", "alternates"])
        File.mkdir_p!(Path.dirname(alternates))
        File.write(alternates, Path.join(projection, "objects") <> "\n")

      {_output, _status} ->
        {:error, :scratch_unavailable}
    end
  end

  defp copy_refs(projection, scratch) do
    Enum.reduce_while(Repos.refs_at(projection), :ok, fn {name, sha}, :ok ->
      case Repos.git(scratch, ["update-ref", name, sha]) do
        {_output, 0} -> {:cont, :ok}
        {_output, _status} -> {:halt, {:error, {:scratch_ref_failed, name}}}
      end
    end)
  end

  defp validate_principal(principal) do
    if String.trim(principal) == "" do
      {:error, :invalid_principal}
    else
      :ok
    end
  end
end
