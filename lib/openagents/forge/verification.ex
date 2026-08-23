defmodule OpenAgents.Forge.Verification do
  @moduledoc """
  Check what the forge serves against the WAL that accepted it, using nothing
  but the WAL and the bare repository on disk.

  The point is to need no one's word. `OpenAgents.Forge.Pushes` acknowledges a
  push only after the WAL accepts it, so the WAL is the record of what was
  pushed and the bare repository is a disposable projection of it. A verifier
  that reads both and compares them can tell whether the projection still
  matches the record, and it reaches that answer without PostgreSQL, without an
  operator credential, and without any row an operator can edit.

  Four findings are possible, and each one names a distinct way the two can
  disagree:

  * `entry_object_missing` — the index names an entry the store cannot produce.
  * `entry_digest_mismatch` — the entry the store produced is not the entry the
    index names. WAL entry keys are content-addressed
    (`OpenAgents.Forge.WAL.entry_key/2`), so rewriting an accepted push's bytes
    changes the key it should have and the recorded key stops matching.
  * `entry_sequence_broken` — the entries are not the contiguous run `0..n-1`.
    A removed or renumbered entry shows up here.
  * `served_refs_diverged` — a ref the repository serves is not the ref the WAL
    last recorded for it, in either direction. A ref moved on disk without a
    push produces this.
  * `object_missing` — the repository cannot produce an object the WAL says a
    push introduced.

  What this cannot do is stated as plainly as what it can. WAL entries are not
  signed and the index is not anchored anywhere outside the operator's own
  storage, so an operator who rewrites an entry, its key, and the index
  together produces a self-consistent log. Content addressing makes tampering
  *evident*, not *impossible*: it catches a partial rewrite, a lost object, and
  a ref moved out of band, and it does not catch a complete and consistent
  forgery. Closing that gap needs a signature or an external anchor, and this
  forge has neither today.
  """

  alias OpenAgents.Forge.{Repos, WAL}

  @internal_ref_prefix "refs/internal/"

  @typedoc "One disagreement between the WAL and what the repository serves."
  @type finding :: %{code: String.t(), detail: map()}

  @typedoc "The verification outcome for one repository."
  @type report :: %{repo: String.t(), entries: non_neg_integer(), findings: [finding()]}

  @doc """
  Verify one repository's served state against its WAL.

  Returns `{:ok, report}` when the two agree and `{:error, report}` when they
  do not. The report always carries the findings list so a caller can render
  every disagreement, not only the first.
  """
  @spec verify(String.t()) :: {:ok, report()} | {:error, report()}
  def verify(storage_key) when is_binary(storage_key) do
    case WAL.read_index(storage_key) do
      {:ok, _generation, index} ->
        entries = WAL.entries(index)

        findings =
          sequence_findings(entries) ++
            entry_findings(storage_key, entries) ++
            ref_findings(storage_key, index) ++
            object_findings(storage_key, entries)

        report(storage_key, length(entries), findings)

      {:error, reason} ->
        report(storage_key, 0, [finding("wal_unreadable", %{"reason" => inspect(reason)})])
    end
  end

  defp report(storage_key, entry_count, []) do
    {:ok, %{repo: storage_key, entries: entry_count, findings: []}}
  end

  defp report(storage_key, entry_count, findings) do
    {:error, %{repo: storage_key, entries: entry_count, findings: findings}}
  end

  defp finding(code, detail), do: %{code: code, detail: detail}

  ## Entries are the contiguous run 0..n-1

  defp sequence_findings(entries) do
    observed = Enum.map(entries, & &1["seq"])
    expected = Enum.to_list(0..(length(entries) - 1)//1)

    if observed == expected do
      []
    else
      [finding("entry_sequence_broken", %{"observed" => observed, "expected" => expected})]
    end
  end

  ## Each entry's bytes still hash to the key the index recorded

  defp entry_findings(storage_key, entries) do
    Enum.flat_map(entries, fn entry -> entry_finding(storage_key, entry) end)
  end

  defp entry_finding(storage_key, %{"seq" => seq, "object" => object}) do
    path =
      Path.join(
        System.tmp_dir!(),
        "forge-verify-#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      # Streamed rather than read: an entry is a whole pack of objects, and a
      # verifier that cannot check a large repository is not a verifier.
      case WAL.get_entry_file(storage_key, object, path) do
        :ok ->
          case WAL.entry_key_file(seq, path) do
            {:ok, ^object} ->
              []

            {:ok, derived} ->
              [
                finding("entry_digest_mismatch", %{
                  "seq" => seq,
                  "recorded" => object,
                  "derived" => derived
                })
              ]

            {:error, reason} ->
              [
                finding("entry_object_missing", %{
                  "seq" => seq,
                  "object" => object,
                  "reason" => inspect(reason)
                })
              ]
          end

        {:error, reason} ->
          [
            finding("entry_object_missing", %{
              "seq" => seq,
              "object" => object,
              "reason" => inspect(reason)
            })
          ]
      end
    after
      File.rm(path)
    end
  end

  defp entry_finding(_storage_key, entry) do
    [finding("entry_object_missing", %{"entry" => inspect(entry)})]
  end

  ## The served refs are the refs the WAL last recorded

  defp ref_findings(storage_key, index) do
    recorded = index |> WAL.refs() |> Map.new()
    served = storage_key |> Repos.refs() |> Map.new()

    diverged =
      recorded
      |> Map.keys()
      |> Kernel.++(Map.keys(served))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(fn name -> Map.get(recorded, name) == Map.get(served, name) end)

    Enum.map(diverged, fn name ->
      finding("served_refs_diverged", %{
        "ref" => name,
        "recorded" => Map.get(recorded, name),
        "served" => Map.get(served, name)
      })
    end)
  end

  ## Every object any accepted push named is present

  defp object_findings(storage_key, entries) do
    path = Repos.bare_path(storage_key)

    entries
    |> Enum.flat_map(fn entry -> Map.to_list(entry["refs"] || %{}) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(fn {_name, sha} ->
      match?({_output, 0}, Repos.git(path, ["cat-file", "-e", sha]))
    end)
    |> Enum.map(fn {name, sha} ->
      finding("object_missing", %{"ref" => name, "object" => sha})
    end)
  end

  @doc """
  The refs a clone receives: every recorded ref except the hidden internal
  bookkeeping namespace.

  `OpenAgents.Forge.Repos` sets `transfer.hideRefs` to `#{@internal_ref_prefix}`,
  where stack boundary commits are retained without being advertised, so a
  clone is complete with respect to this set and not with respect to the raw
  WAL ref map.
  """
  @spec exportable_refs(map()) :: map()
  def exportable_refs(refs) when is_map(refs) do
    Map.reject(refs, fn {name, _sha} -> String.starts_with?(name, @internal_ref_prefix) end)
  end
end
