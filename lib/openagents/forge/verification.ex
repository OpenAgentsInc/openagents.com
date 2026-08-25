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

  Each finding names a distinct way the two can disagree:

  * `entry_object_missing` — the index names an entry the store cannot produce.
  * `entry_digest_mismatch` — the entry the store produced is not the entry the
    index names. WAL entry keys are content-addressed
    (`OpenAgents.Forge.WAL.entry_key/2`), so rewriting an accepted push's bytes
    changes the key it should have and the recorded key stops matching.
  * `entry_sequence_broken` — the entries are not the contiguous run `0..n-1`.
    A removed or renumbered entry shows up here.
  * `served_refs_diverged` — the repository serves a ref state the WAL never
    recorded at or after the sequence this projection claims, in either
    direction. A ref moved on disk without a push produces this; a ref an entry
    this node has not replayed yet does not, and the next section is where that
    line is drawn.
  * `applied_seq_beyond_log` — the projection's applied-sequence marker names a
    sequence the log does not have, so it claims an entry that is not there.
  * `object_missing` — the repository cannot produce an object the WAL says a
    push it has applied introduced.
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

  Three more findings come before any of that, because a check of the wrong
  repository is worse than no check. The caller names a repository by storage
  key or by name, `OpenAgents.Forge.RepoRef` resolves the two apart, and a
  reference that settles on no single repository stops there:
  `repository_not_found`, `repository_name_ambiguous` for a name two
  repositories answer to, and `repository_lookup_unavailable` when the lookup
  a name needs could not be made. None of them builds a path out of the string,
  which is what made an absent repository report `wal_unreadable` — the finding
  that means "your log is gone" — for a log that was never there (issue #190).

  ## Behind the log is not the same as disagreeing with it

  One WAL, many projections. Every node keeps its own bare repository on its
  own disk and brings it up by replaying entries when it reads
  (`OpenAgents.Forge.Sync`), so a node is routinely a few entries behind a push
  another node accepted seconds ago. That is the ordinary state of a healthy
  fleet, and a verifier that calls it tampering is a verifier people learn to
  ignore — which is what this reported until issue #251.

  The two are told apart by locating the projection on the log rather than
  comparing it to the head. The served ref map is compared against the ref map
  each entry recorded as its post-state, and the greatest sequence whose
  recorded state the projection serves exactly is its `:position`.

  * A projection that sits at some sequence on the log is **behind** it by
    `head_seq - position` entries. No finding, `status: :behind`, and
    `{:ok, report}` — nothing contradicts the log.
  * A projection that sits at no sequence on the log **disagrees** with it.
    `served_refs_diverged` names each ref, `status: :diverged`, and
    `{:error, report}`.

  Lag only ever runs one way, which is what makes the boundary tight. A node
  that has not replayed an entry is missing what that entry introduced; it can
  never serve a ref the log has no record of, a ref at a value the log never
  recorded, or a ref value the log recorded *before* the state the node is
  serving. Each of those is still a finding however far behind the node is, and
  `object_missing` is still a finding for every object an entry at or below the
  projection's position introduced.

  The applied-sequence marker `OpenAgents.Forge.Sync` writes
  (`OpenAgents.Forge.Repos.applied_seq/1`) is the projection's own claim about
  itself, so it bounds the search rather than answering it. Only sequences at
  or above the marker are candidates: a projection serving a state older than
  the sequence it claims to have applied is reported, and a marker rolled
  forward to the head therefore silences nothing — it makes the check stricter,
  because the head's refs still have to be there. A marker rolled back to `-1`
  widens the search to the whole log and to the empty state, which is the one
  thing it buys and it buys nothing else: every candidate is still a state the
  log itself records, so no ref value the log never held is ever admitted. A
  marker naming a sequence the log does not have is `applied_seq_beyond_log`,
  which is how a log truncated at the tail surfaces on a node that had already
  applied past it.

  What this cannot separate is named rather than hidden. A projection rolled
  back to a state the log itself passed through, with its marker rolled back to
  match, is indistinguishable from a node that has not finished replaying,
  because from the WAL and the repository alone those are the same observation.
  It is reported as behind, not as clean, and a node that stays behind while
  its peers catch up is what `verify_cluster/2` makes visible.

  ## One repository, three answers

  Because each node answers for its own projection, `verify/2` answers for one
  node and says which: the report carries `:node`, `:applied_seq`,
  `:position`, `:behind`, and `:head_seq`. `verify_cluster/2` asks every member
  and combines the answers into one verdict that does not flicker while a node
  replays: `:verified` when every member answered and every one is current,
  `:converging` when nothing contradicts the log and some member is behind or
  silent, `:diverged` when some member contradicts the log or two members
  disagree about the log itself, and `:unavailable` when nothing was checked.
  Lag moves a fleet between `:verified` and `:converging`, which is a state
  that clears itself; only a real disagreement reaches `:diverged`.

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

  alias OpenAgents.Cluster
  alias OpenAgents.Forge.{RepoRef, Repos, WAL}

  @internal_ref_prefix "refs/internal/"
  @cluster_timeout_ms 30_000

  @typedoc "One disagreement between the WAL and what the repository serves."
  @type finding :: %{code: String.t(), detail: map()}

  @typedoc "An independently held commitment to one entry's link."
  @type anchor :: %{seq: non_neg_integer(), link: String.t()}

  @typedoc "Where one node's projection sits relative to the log."
  @type status :: :current | :behind | :diverged | :unresolved

  @typedoc "The verification outcome for one repository, on one node."
  @type report :: %{
          repo: RepoRef.ref(),
          storage_key: RepoRef.storage_key() | nil,
          node: node(),
          entries: non_neg_integer(),
          findings: [finding()],
          head: anchor() | nil,
          chained_from: non_neg_integer() | nil,
          status: status(),
          head_seq: integer(),
          applied_seq: integer(),
          position: integer() | nil,
          behind: non_neg_integer() | nil
        }

  @typedoc "One member's contribution to a fleet-wide answer."
  @type node_result :: %{
          node: node(),
          status: status() | :unreachable,
          head_seq: integer() | nil,
          applied_seq: integer() | nil,
          position: integer() | nil,
          behind: non_neg_integer() | nil,
          entries: non_neg_integer() | nil,
          head: anchor() | nil,
          findings: [finding()],
          reason: term() | nil
        }

  @typedoc "The verification outcome for one repository, across the fleet."
  @type cluster_report :: %{
          repo: RepoRef.ref(),
          status: :verified | :converging | :diverged | :unavailable,
          head_seq: integer() | nil,
          log_agreement: :agreed | :disagreed | :unknown,
          nodes: [node_result()],
          findings: [%{node: node(), code: String.t(), detail: map()}]
        }

  @doc """
  Verify one repository's served state against its WAL.

  `repo_ref` is either a storage key or a name — the `openagents.com` or
  `OpenAgentsInc/openagents.com` a person actually has. `OpenAgents.Forge.RepoRef`
  resolves the two apart, and the report names both what was asked for
  (`:repo`) and the key that was checked (`:storage_key`), so the mapping is
  visible rather than assumed. A name that names no repository, or two, is a
  finding — `repository_not_found` or `repository_name_ambiguous` — and never a
  path built out of the name, which is what made an absent repository look
  half-alive (issue #190).

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

  This answers for one node's projection, and says so: `:node`, `:applied_seq`,
  `:position`, `:behind`, and `:head_seq` place the answer on the log. A node
  that has not replayed an entry yet returns `{:ok, report}` with
  `status: :behind` and no findings, because being behind is not a
  disagreement. Use `verify_cluster/2` for the fleet's answer.
  """
  @spec verify(RepoRef.ref(), keyword()) :: {:ok, report()} | {:error, report()}
  def verify(repo_ref, opts \\ []) when is_binary(repo_ref) and is_list(opts) do
    case RepoRef.storage_key(repo_ref) do
      {:ok, storage_key} ->
        verify_storage_key(repo_ref, storage_key, opts)

      {:error, reason} ->
        unresolved(repo_ref, nil, [resolution_finding(repo_ref, reason)])
    end
  end

  defp verify_storage_key(repo_ref, storage_key, opts) do
    case WAL.read_index(storage_key) do
      {:ok, _generation, index} ->
        entries = WAL.entries(index)
        projection = locate(storage_key, entries)

        findings =
          sequence_findings(entries) ++
            entry_findings(storage_key, entries) ++
            marker_findings(projection) ++
            ref_findings(entries, projection) ++
            object_findings(storage_key, entries, projection) ++
            reachability_findings(storage_key, entries, projection) ++
            chain_findings(entries) ++
            anchor_findings(entries, normalize_anchor(opts[:anchor]))

        report(repo_ref, storage_key, entries, findings, projection)

      {:error, reason} ->
        unresolved(repo_ref, storage_key, [
          finding("wal_unreadable", %{"reason" => inspect(reason)})
        ])
    end
  end

  defp resolution_finding(repo_ref, :ambiguous_name),
    do: finding("repository_name_ambiguous", %{"repo" => repo_ref})

  defp resolution_finding(repo_ref, :repository_lookup_unavailable),
    do: finding("repository_lookup_unavailable", %{"repo" => repo_ref})

  defp resolution_finding(repo_ref, _not_found),
    do: finding("repository_not_found", %{"repo" => repo_ref})

  # Nothing was compared: the reference named no single repository, or the log
  # could not be read. A node that could not check is not a node that found
  # something, and a fleet answer must not read one as the other.
  defp unresolved(repo, storage_key, findings) do
    {:error,
     %{
       repo: repo,
       storage_key: storage_key,
       node: node(),
       entries: 0,
       findings: findings,
       head: nil,
       chained_from: nil,
       status: :unresolved,
       head_seq: -1,
       applied_seq: -1,
       position: nil,
       behind: nil
     }}
  end

  defp report(repo, storage_key, entries, findings, projection) do
    report = %{
      repo: repo,
      storage_key: storage_key,
      node: node(),
      entries: length(entries),
      findings: findings,
      head: head(entries),
      chained_from: chained_from(entries),
      status: status(findings, projection),
      head_seq: projection.head_seq,
      applied_seq: projection.applied_seq,
      position: projection.position,
      behind: projection.behind
    }

    if findings == [], do: {:ok, report}, else: {:error, report}
  end

  defp status([_finding | _rest], _projection), do: :diverged
  defp status([], %{behind: 0}), do: :current
  defp status([], _projection), do: :behind

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

  ## Where on the log this node's projection sits

  # The projection's own marker says which entries it claims to have applied,
  # and the served refs say what it is actually serving. The marker bounds the
  # search; the refs decide it. A projection is *on* the log when it serves,
  # exactly, the post-state some entry recorded — every ref that entry recorded
  # and no other. The greatest such sequence at or above the marker is its
  # position, and the distance from there to the head is how far behind it is.
  #
  # Everything below the marker is excluded because the projection has already
  # claimed those entries: serving an older state than it claims to hold is a
  # disagreement, not lag. Nothing above the head can be a candidate, so no
  # marker can admit a state the log does not record.
  defp locate(storage_key, entries) do
    head_seq = head_seq(entries)
    applied_seq = Repos.applied_seq(storage_key)
    served = storage_key |> Repos.refs() |> Map.new()
    position = position(entries, served, applied_seq, head_seq)

    %{
      head_seq: head_seq,
      applied_seq: applied_seq,
      served: served,
      position: position,
      behind: position && head_seq - position,
      # The sequence whose state this projection is checked against: where it
      # actually is, or — when it is nowhere on the log — where it claims to be.
      checked_seq: position || min(applied_seq, head_seq)
    }
  end

  defp head_seq(entries) do
    case List.last(entries) do
      nil -> -1
      entry -> entry["seq"]
    end
  end

  defp position(entries, served, applied_seq, head_seq) do
    on_log =
      entries
      |> Enum.filter(&(&1["seq"] >= applied_seq and &1["seq"] <= head_seq))
      |> Enum.reverse()
      |> Enum.find_value(fn entry -> if entry_refs(entry) == served, do: entry["seq"] end)

    # Sequence -1 is the empty projection, which is every node before it
    # replays anything. It is a candidate only when the marker claims nothing.
    cond do
      on_log != nil -> on_log
      applied_seq <= -1 and served == %{} -> -1
      true -> nil
    end
  end

  defp entry_refs(entry) do
    case entry && Map.get(entry, "refs") do
      refs when is_map(refs) -> refs
      _absent -> %{}
    end
  end

  defp recorded_refs_at(_entries, seq) when seq < 0, do: %{}

  defp recorded_refs_at(entries, seq) do
    case Enum.find(entries, &(&1["seq"] == seq)) do
      nil -> entries |> List.last() |> entry_refs()
      entry -> entry_refs(entry)
    end
  end

  ## The projection claims no more of the log than the log holds

  # A marker past the end of the log is not lag in either direction: the
  # projection says it applied an entry that is not there. A tail truncated out
  # of the WAL leaves `0..n-1` contiguous and so passes every other check; this
  # is where a node that had already applied past the truncation reports it.
  defp marker_findings(%{applied_seq: applied_seq, head_seq: head_seq})
       when applied_seq > head_seq do
    [
      finding("applied_seq_beyond_log", %{
        "applied_seq" => applied_seq,
        "head_seq" => head_seq
      })
    ]
  end

  defp marker_findings(_projection), do: []

  ## The served refs are a state the WAL recorded

  # A projection with a position is serving a state the log records, so there
  # is nothing to report: it is current or behind, which `:status` says. One
  # without a position is serving something the log never recorded at or after
  # the sequence it claims, and every ref that differs from the claimed state
  # is named.
  defp ref_findings(_entries, %{position: position}) when position != nil, do: []

  defp ref_findings(entries, projection) do
    recorded = recorded_refs_at(entries, projection.checked_seq)
    served = projection.served

    recorded
    |> Map.keys()
    |> Kernel.++(Map.keys(served))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(fn name -> Map.get(recorded, name) == Map.get(served, name) end)
    |> Enum.map(fn name ->
      finding("served_refs_diverged", %{
        "ref" => name,
        "recorded" => Map.get(recorded, name),
        "served" => Map.get(served, name),
        "at_seq" => projection.checked_seq
      })
    end)
  end

  ## Every object an applied push named is present

  # Bounded by where the projection is. An object introduced by an entry the
  # node has not replayed is absent for the same reason the ref is, and both
  # are the lag `:behind` reports. An object introduced at or below the
  # projection's own position is not: it applied that entry.
  defp object_findings(storage_key, entries, projection) do
    path = Repos.bare_path(storage_key)

    entries
    |> Enum.filter(&(&1["seq"] <= projection.checked_seq))
    |> Enum.flat_map(fn entry -> Map.to_list(entry_refs(entry)) end)
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
  #
  # The tips are the ones recorded at the projection's position, because a
  # clone answered by this node walks the state this node holds, not the state
  # the head describes.
  defp reachability_findings(storage_key, entries, projection) do
    path = Repos.bare_path(storage_key)

    tips =
      entries
      |> recorded_refs_at(projection.checked_seq)
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
  Verify one repository across every node that serves it.

  Each member answers for its own projection, so the fleet's answer is the
  combination of theirs. The verdict is deliberately insensitive to lag:

  * `:verified` — every member answered and every one is at the head.
  * `:converging` — nothing contradicts the log, and at least one member is
    behind it or did not answer. This state clears itself as nodes replay.
  * `:diverged` — a member's projection contradicts the log, or two members
    disagree about the log itself. Nothing here clears itself.
  * `:unavailable` — nothing was checked: no member answered, or every member
    could not resolve the repository or read its log.

  Returns `{:ok, cluster_report}` for `:verified` and `:converging`, and
  `{:error, cluster_report}` for `:diverged` and `:unavailable`. Findings are
  carried with the node that produced them, so a reader can tell one node's
  answer from the fleet's.

  Options:

  * `:anchor` — passed through to `verify/2` on every member. Because the
    anchor comes from outside the log, this is also how the members are checked
    against one repository history rather than only against each other.
  * `:members` — a zero-arity function returning the members to ask. Defaults
    to `OpenAgents.Cluster.members/0`.
  * `:rpc` — a five-arity function with `:erpc.call/5`'s shape.
  * `:timeout_ms` — per-member deadline.

  This reaches no database either: membership comes from `OpenAgents.Cluster`,
  which reads `Node`, and each member runs the same WAL-and-repository check.

  `:log_agreement` compares the members that reported a chain link at the same
  sequence. Two nodes reading one shared log cannot disagree there, so
  `:disagreed` means one of them is not reading the log the other is. Members
  at different sequences have nothing comparable, and the value is `:unknown`
  when no two members reported the same one.
  """
  @spec verify_cluster(RepoRef.ref(), keyword()) ::
          {:ok, cluster_report()} | {:error, cluster_report()}
  def verify_cluster(repo_ref, opts \\ []) when is_binary(repo_ref) and is_list(opts) do
    members = Keyword.get(opts, :members, &Cluster.members/0).() |> Enum.uniq()
    rpc = Keyword.get(opts, :rpc, &:erpc.call/5)
    timeout_ms = Keyword.get(opts, :timeout_ms, @cluster_timeout_ms)
    verify_opts = Keyword.take(opts, [:anchor])

    results =
      members
      |> Task.async_stream(
        fn member -> ask(member, repo_ref, verify_opts, rpc, timeout_ms) end,
        ordered: true,
        timeout: timeout_ms + 1_000,
        on_timeout: :kill_task,
        max_concurrency: max(1, length(members))
      )
      |> Enum.zip(members)
      |> Enum.map(fn
        {{:ok, result}, member} -> node_result(member, result)
        {{:exit, reason}, member} -> unreachable_result(member, reason)
      end)

    cluster_report(repo_ref, results)
  end

  defp ask(member, repo_ref, verify_opts, _rpc, _timeout_ms) when member == node(),
    do: verify(repo_ref, verify_opts)

  defp ask(member, repo_ref, verify_opts, rpc, timeout_ms) do
    rpc.(member, __MODULE__, :verify, [repo_ref, verify_opts], timeout_ms)
  catch
    kind, reason -> {:unreachable, {kind, reason}}
  end

  defp node_result(member, {ok_or_error, report}) when ok_or_error in [:ok, :error] do
    %{
      node: member,
      status: report.status,
      head_seq: report.head_seq,
      applied_seq: report.applied_seq,
      position: report.position,
      behind: report.behind,
      entries: report.entries,
      head: report.head,
      findings: report.findings,
      reason: nil
    }
  end

  defp node_result(member, {:unreachable, reason}), do: unreachable_result(member, reason)
  defp node_result(member, other), do: unreachable_result(member, {:invalid_result, other})

  defp unreachable_result(member, reason) do
    %{
      node: member,
      status: :unreachable,
      head_seq: nil,
      applied_seq: nil,
      position: nil,
      behind: nil,
      entries: nil,
      head: nil,
      findings: [],
      reason: reason
    }
  end

  defp cluster_report(repo_ref, results) do
    agreement = log_agreement(results)

    findings =
      Enum.flat_map(results, fn result ->
        Enum.map(result.findings, &Map.put(&1, :node, result.node))
      end)

    report = %{
      repo: repo_ref,
      status: cluster_status(results, agreement),
      head_seq: head_seq_across(results),
      log_agreement: agreement,
      nodes: results,
      findings: findings
    }

    if report.status in [:verified, :converging], do: {:ok, report}, else: {:error, report}
  end

  defp head_seq_across(results) do
    case results |> Enum.map(& &1.head_seq) |> Enum.reject(&is_nil/1) do
      [] -> nil
      seqs -> Enum.max(seqs)
    end
  end

  defp cluster_status(results, agreement) do
    checked = Enum.filter(results, &(&1.status in [:current, :behind, :diverged]))

    cond do
      Enum.any?(results, &(&1.status == :diverged)) -> :diverged
      agreement == :disagreed -> :diverged
      checked == [] -> :unavailable
      # Some member cannot see a repository the others verified, which is a
      # disagreement about the fleet rather than a lag window.
      Enum.any?(results, &(&1.status == :unresolved)) -> :diverged
      Enum.all?(results, &(&1.status == :current)) -> :verified
      true -> :converging
    end
  end

  # Two nodes that reported a link for the same sequence must have reported the
  # same link: the WAL is one shared log. Nodes at different sequences are
  # compared on nothing, which is why lag cannot reach this value.
  defp log_agreement(results) do
    by_seq =
      results
      |> Enum.map(& &1.head)
      |> Enum.reject(&is_nil/1)
      |> Enum.group_by(& &1.seq, & &1.link)

    comparable = Enum.filter(by_seq, fn {_seq, links} -> length(links) > 1 end)

    cond do
      comparable == [] -> :unknown
      Enum.all?(comparable, fn {_seq, links} -> Enum.uniq(links) |> length() == 1 end) -> :agreed
      true -> :disagreed
    end
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
