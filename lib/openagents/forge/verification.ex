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
  * `object_unreachable` — the repository produces every ref tip but cannot
    produce something an advertised ref reaches, so a clone aborts partway
    through the walk even though every tip resolves.
  * `chain_link_mismatch` — an entry's recorded link is not the link its own
    contents and its predecessor's link produce (`OpenAgents.Forge.WAL.chain_link/2`).
  * `chain_link_missing` — an entry carries no link although an earlier entry
    does, so the chain stops in the middle of the log.
  * `anchor_mismatch` — the caller supplied an anchor and the log carries a
    different link at that sequence.
  * `anchor_unreachable` — the caller supplied an anchor for a sequence this
    log does not have, or for an entry that carries no link.

  What this cannot do is stated as plainly as what it can. Content addressing
  and the chain make tampering *evident*, not *impossible*. An operator who
  rewrites an entry, its key, the index, and every link after it produces a
  self-consistent log, and `verify/2` called with no anchor reports it clean.
  The chain buys one thing: a rewrite can no longer be local, because every
  entry after the rewritten one changes. That is what makes a single remembered
  link enough to check a whole prefix, which is what `verify/2`'s `:anchor`
  option checks. Supplying an anchor is the caller's job. A pusher gets one for
  free: `OpenAgents.Forge.GitHTTP` returns the sequence and link of an accepted
  push in the `git receive-pack` side band, so `git push` prints it and the
  pusher can keep it. Nothing is published to a stranger yet —
  `docs/2026-08-23-forge-wal-anchoring.md` stages that work. Withholding is out
  of scope in every case: an operator who serves nothing is not detected here,
  only an operator who serves something other than what was pushed.
  """

  alias OpenAgents.Forge.{Repos, WAL}

  @internal_ref_prefix "refs/internal/"

  @typedoc "One disagreement between the WAL and what the repository serves."
  @type finding :: %{code: String.t(), detail: map()}

  @typedoc "An independently held commitment to one entry's link."
  @type anchor :: %{seq: non_neg_integer(), link: String.t()}

  @typedoc "The verification outcome for one repository."
  @type report :: %{
          repo: String.t(),
          entries: non_neg_integer(),
          findings: [finding()],
          head: anchor() | nil,
          chained_from: non_neg_integer() | nil
        }

  @doc """
  Verify one repository's served state against its WAL.

  Returns `{:ok, report}` when the two agree and `{:error, report}` when they
  do not. The report always carries the findings list so a caller can render
  every disagreement, not only the first.

  Options:

  * `:anchor` — a `%{seq: sequence, link: link}` commitment the caller obtained
    somewhere other than this log. The verifier checks the log against it, and
    a consistent rewrite of anything at or before that sequence is reported.
    Without one, a consistent rewrite is not detectable here.

  The report also carries `:head`, the last entry's `%{seq:, link:}`, which is
  what a caller remembers so it can anchor a later verification, and
  `:chained_from`, the first sequence that carries a link. Entries before that
  sequence predate the chain and are not covered by it.
  """
  @spec verify(String.t(), keyword()) :: {:ok, report()} | {:error, report()}
  def verify(storage_key, opts \\ []) when is_binary(storage_key) and is_list(opts) do
    case WAL.read_index(storage_key) do
      {:ok, _generation, index} ->
        entries = WAL.entries(index)

        findings =
          sequence_findings(entries) ++
            entry_findings(storage_key, entries) ++
            ref_findings(storage_key, index) ++
            object_findings(storage_key, entries) ++
            reachability_findings(storage_key, index) ++
            chain_findings(entries) ++
            anchor_findings(entries, normalize_anchor(opts[:anchor]))

        report(storage_key, entries, findings)

      {:error, reason} ->
        report(storage_key, [], [finding("wal_unreadable", %{"reason" => inspect(reason)})])
    end
  end

  defp report(storage_key, entries, findings) do
    report = %{
      repo: storage_key,
      entries: length(entries),
      findings: findings,
      head: head(entries),
      chained_from: chained_from(entries)
    }

    if findings == [], do: {:ok, report}, else: {:error, report}
  end

  defp head(entries) do
    case List.last(entries) do
      nil ->
        nil

      entry ->
        case WAL.entry_link(entry) do
          nil -> nil
          link -> %{seq: entry["seq"], link: link}
        end
    end
  end

  defp chained_from(entries) do
    case Enum.find(entries, &(WAL.entry_link(&1) != nil)) do
      nil -> nil
      entry -> entry["seq"]
    end
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

  ## Every object a clone walks into is present

  # `object_missing` checks the ref tips an accepted push named. A clone does
  # not stop at the tips: it walks each one into its ancestors, and git
  # `upload-pack` aborts the entire transfer on the first object it cannot
  # read. A repository can therefore hold every tip the WAL recorded and still
  # be impossible to clone, which is what #179 was.
  #
  # The population is the exportable ref set — what a clone actually asks for
  # — and it is walked by git rather than enumerated here, so an object nobody
  # thought to name is covered by the same walk that would fail a clone.
  # A shallow graft the repository legitimately carries stops the walk at its
  # boundary, so a grafted repository is clean here: it is servable, and
  # servable is the claim.
  defp reachability_findings(storage_key, index) do
    path = Repos.bare_path(storage_key)

    tips =
      index
      |> WAL.refs()
      |> exportable_refs()
      |> Map.values()
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(fn sha -> match?({_output, 0}, Repos.git(path, ["cat-file", "-e", sha])) end)

    if tips == [] do
      []
    else
      unreachable_findings(path, tips)
    end
  end

  defp unreachable_findings(path, tips) do
    # Discarded output in the common case: a repository whose history walks
    # is the answer, and its object list is not worth carrying.
    case Repos.git(path, ["rev-list", "--objects", "--quiet"] ++ tips) do
      {_output, 0} -> []
      {_output, _status} -> walk_failure_findings(path, tips)
    end
  end

  defp walk_failure_findings(path, tips) do
    case Repos.git(path, ["rev-list", "--missing=print"] ++ tips) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "?"))
        |> Enum.map(&(&1 |> binary_part(1, byte_size(&1) - 1) |> String.split(" ") |> hd()))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&finding("object_unreachable", %{"object" => &1}))

      {_output, _status} ->
        [finding("object_unreachable", %{"reason" => "history walk failed"})]
    end
  end

  ## Each entry commits to the entry before it

  defp chain_findings(entries) do
    {findings, _previous, _chained?} =
      Enum.reduce(entries, {[], "", false}, &chain_finding/2)

    Enum.reverse(findings)
  end

  defp chain_finding(entry, {findings, previous, chained?}) do
    case WAL.entry_link(entry) do
      nil when chained? ->
        {[finding("chain_link_missing", %{"seq" => entry["seq"]}) | findings], "", true}

      nil ->
        {findings, "", false}

      link ->
        # The next entry chains from the link this one *records*, not from the
        # one it should have recorded, so a single altered entry reports once
        # rather than turning every entry after it into a second finding.
        {chain_link_findings(entry, previous, link) ++ findings, link, true}
    end
  end

  defp chain_link_findings(entry, previous, link) do
    case WAL.chain_link(previous, entry) do
      {:ok, ^link} ->
        []

      {:ok, derived} ->
        [
          finding("chain_link_mismatch", %{
            "seq" => entry["seq"],
            "recorded" => link,
            "derived" => derived
          })
        ]

      :error ->
        [finding("chain_link_mismatch", %{"seq" => entry["seq"], "recorded" => link})]
    end
  end

  ## The log agrees with a commitment the caller holds independently

  defp anchor_findings(_entries, nil), do: []

  defp anchor_findings(entries, %{seq: seq, link: link}) do
    entry = Enum.find(entries, &(&1["seq"] == seq))

    case entry && WAL.entry_link(entry) do
      ^link ->
        []

      nil ->
        [
          finding("anchor_unreachable", %{
            "seq" => seq,
            "entries" => length(entries),
            "reason" => if(entry, do: "entry carries no link", else: "no entry at this sequence")
          })
        ]

      recorded ->
        [finding("anchor_mismatch", %{"seq" => seq, "anchored" => link, "recorded" => recorded})]
    end
  end

  defp normalize_anchor(%{seq: seq, link: link}) when is_integer(seq) and is_binary(link),
    do: %{seq: seq, link: link}

  defp normalize_anchor(%{"seq" => seq, "link" => link}) when is_integer(seq) and is_binary(link),
    do: %{seq: seq, link: link}

  defp normalize_anchor(_absent_or_malformed), do: nil

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
