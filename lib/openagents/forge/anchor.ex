defmodule OpenAgents.Forge.Anchor do
  @moduledoc """
  The published commitment to the forge's WAL (`EXIT-005`, ADR 0008).

  `EXIT-002` compares two things the operator holds, and `EXIT-005` makes a
  rewrite of either one total rather than local: change any accepted entry and
  every link after it changes, so one link remembered outside the operator's
  storage checks the whole prefix before it. `git push` hands that link to the
  pusher. This module hands it to everyone else.

  Every interval, a document naming each public repository's entry count, head
  sequence, head chain link, and ref-map digest is written to
  `forge_wal_anchors` and served verbatim at
  `/.well-known/openagents-forge-anchor.json`.

  ## What this proves

  On its own, nothing. The operator serves the document and could serve any
  document. Saying so on the document itself, in this moduledoc, and on
  `/status` is deliberate: a publication surface that reads as proof while
  depending on the operator is worse than the gap it papers over.

  What it buys is that a commitment becomes cheap for a third party to keep a
  copy of, and a copy is the thing that contradicts a rewrite:

  * A reader now holds a commitment covering every public repository's whole
    log prefix, not only the pushes they made themselves.
  * Each anchor names `previous_digest`, the digest of the anchor before it, so
    the published sequence is itself a hash chain. One archived anchor pins
    every anchor before it, the way an entry link pins every entry before it.
  * `published_at` advances every interval whether or not the log moved, so a
    reader can tell publication has stopped. A halt is otherwise
    indistinguishable from an outage.

  ## What this does not prove

  Nothing is *witnessed*: no party other than the operator attests that this
  document existed at this time with these contents, which is why
  `OpenAgents.Forge.Independence` publishes `anchor_published` and
  `anchor_witnessed` as two separate facts and stays degraded on the second.
  A reader who kept no copy holds nothing. Everything after the last anchor is
  unanchored, so the exposure window is the interval. A split view is narrowed
  and not closed. Withholding is untouched: an operator who serves nothing,
  serves stale state, or refuses a clone is not detected by any of this.
  Completeness is untouched: an anchor over a truncated log is a valid anchor
  over a truncated log.

  The head is not signed. A signature made with a key the operator holds, over
  a document the operator serves, adds nothing against the operator — see
  `docs/2026-08-23-forge-wal-anchoring.md` section 3.2 and ADR 0008.

  ## Bounds

  The population is the repositories an anonymous reader can already see —
  `OpenAgents.Repositories.readable_by/2` with no user — because publishing a
  private repository's name and push count would contradict `TRANSPARENCY-001`,
  where an unpublished repository is indistinguishable from one that does not
  exist. A private repository's log is therefore anchored for nobody, and its
  pusher's own receipt stays the only commitment to it.

  Nothing here runs on the push path and nothing here can fail a push. The
  publisher is a scheduled job, it only reads the WAL, and a repository whose
  index it cannot read is reported as unreadable in the document rather than
  omitted from it.
  """

  import Ecto.Query, warn: false

  alias OpenAgents.Forge.{Verification, WAL, WALAnchor}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @schema "openagents.forge_wal_anchor.v1"
  @path "/.well-known/openagents-forge-anchor.json"
  @decision "docs/decisions/0008-publish-the-forge-wal-anchor-at-a-well-known-path.md"

  @trust "This document is published by the forge operator and witnessed by nobody. " <>
           "It proves nothing on its own: an operator who rewrote the log would serve " <>
           "the rewritten head here too. Its value is that keeping a copy is cheap, and " <>
           "a copy you kept is what contradicts a later rewrite."

  @verify "Keep this file. Later, run OpenAgents.Forge.Verification.verify/2 against the " <>
            "forge's WAL with anchor: %{seq: head_seq, link: head_link} for the repository " <>
            "you care about; a log rewritten at or before that sequence reports " <>
            "anchor_mismatch. Check previous_digest against the sha256 of the anchor file " <>
            "you kept before this one."

  @doc "The well-known path the anchor document is served at."
  @spec path() :: String.t()
  def path, do: @path

  @doc "The document schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  The most recently published anchor, or `nil` when none has been published.
  """
  @spec latest() :: WALAnchor.t() | nil
  def latest do
    Repo.one(from anchor in WALAnchor, order_by: [desc: anchor.anchor_seq], limit: 1)
  end

  @doc """
  Whether any anchor has been published.

  A read that fails answers `false`. The failure direction is deliberate: the
  disclosure this feeds claims less than reality rather than more.
  """
  @spec published?() :: boolean()
  def published? do
    Repo.exists?(WALAnchor)
  rescue
    _database_unavailable -> false
  catch
    _kind, _reason -> false
  end

  @doc """
  Build, store, and serve the next anchor.

  Returns `{:ok, anchor}`, or `{:error, reason}` when the row could not be
  written. Two nodes publishing in the same interval race on the unique
  `anchor_seq`; the loser reports `:anchor_seq_taken` and retries next tick,
  because a published sequence with two different documents behind it would
  break the chain a reader walks.
  """
  @spec publish(DateTime.t()) :: {:ok, WALAnchor.t()} | {:error, term()}
  def publish(now \\ DateTime.utc_now()) do
    previous = latest()
    seq = if previous, do: previous.anchor_seq + 1, else: 0
    previous_digest = previous && previous.digest

    body =
      seq
      |> document(previous_digest, now)
      |> Jason.encode!(pretty: true)

    %WALAnchor{}
    |> WALAnchor.changeset(%{
      anchor_seq: seq,
      digest: digest(body),
      previous_digest: previous_digest,
      body: body,
      published_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, anchor} -> {:ok, anchor}
      {:error, _changeset} -> {:error, :anchor_seq_taken}
    end
  end

  @doc """
  The anchor document for sequence `seq`, before encoding.

  Public so a test can compare the served bytes against the log rather than
  against a fixture.
  """
  @spec document(non_neg_integer(), String.t() | nil, DateTime.t()) :: map()
  def document(seq, previous_digest, now) do
    %{
      "schema" => @schema,
      "anchor_seq" => seq,
      "published_at" => DateTime.to_iso8601(now),
      "previous_digest" => previous_digest,
      "repositories" => Enum.map(published_repositories(), &repository_anchor/1),
      "signed" => false,
      "witnessed" => false,
      "trust" => @trust,
      "verify" => @verify,
      "decision" => @decision
    }
  end

  @doc "`sha256:<hex>` over the exact bytes a reader fetches."
  @spec digest(binary()) :: String.t()
  def digest(body) when is_binary(body) do
    "sha256:" <> (:sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower))
  end

  @doc """
  The repositories an anonymous reader can already see, oldest name first.

  This is the population, and it is read through the same predicate every
  anonymous surface reads, so a repository that stops being public stops being
  anchored in the same commit.
  """
  @spec published_repositories() :: [Repository.t()]
  def published_repositories do
    Repository
    |> Repositories.readable_by(nil)
    |> order_by([repository], asc: repository.owner_key, asc: repository.name_key)
    |> Repo.all()
  end

  defp repository_anchor(%Repository{} = repository) do
    base = %{"repo" => "#{repository.owner}/#{repository.name}"}

    case WAL.read_index(repository.storage_key) do
      {:ok, _generation, index} ->
        entries = WAL.entries(index)

        Map.merge(base, %{
          "entries" => length(entries),
          "head_seq" => head(entries)[:seq],
          "head_link" => head(entries)[:link],
          "chained_from" => chained_from(entries),
          "refs_digest" => refs_digest(index)
        })

      {:error, :not_found} ->
        # A repository nobody has pushed to has no index. That is an empty
        # record, not an unreadable one.
        Map.merge(base, %{
          "entries" => 0,
          "head_seq" => nil,
          "head_link" => nil,
          "chained_from" => nil,
          "refs_digest" => nil
        })

      {:error, _reason} ->
        # Reported rather than dropped: a repository silently missing from the
        # anchor is exactly what an operator hiding one would look like.
        Map.merge(base, %{"unreadable" => true})
    end
  end

  defp head(entries) do
    case List.last(entries) do
      nil -> %{}
      entry -> %{seq: entry["seq"], link: WAL.entry_link(entry)}
    end
  end

  defp chained_from(entries) do
    case Enum.find(entries, &(WAL.entry_link(&1) != nil)) do
      nil -> nil
      entry -> entry["seq"]
    end
  end

  # The refs a clone actually receives, so a reader can check what they cloned
  # against what was anchored. Length-delimited for the same reason the chain
  # encoding is: no two distinct ref maps may encode alike.
  defp refs_digest(index) do
    index
    |> WAL.refs()
    |> Verification.exportable_refs()
    |> Enum.sort()
    |> Enum.map_join(fn {name, sha} ->
      "#{byte_size(name)}:#{name}#{byte_size(sha)}:#{sha}"
    end)
    |> digest()
  end
end
