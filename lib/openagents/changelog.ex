defmodule OpenAgents.Changelog do
  @moduledoc """
  The public changelog projection (spec §3,
  `docs/plans/2026-08-19-transparency-spec-and-roadmap.md`): one bounded
  timeline joining authored `changelog_entries` to the forge receipt chain,
  plus agent-layer-only rows for receipted deploys nobody wrote a note for.

  Same posture as `OpenAgents.NetworkStatus` (STATUS-001 lineage): computed
  bounded, briefly cached in `:persistent_term` so anonymous page traffic
  can never become a query storm, degrades per-field, and is never
  authority — the receipts are. Disclosure is governed per repo by
  `OpenAgents.Forge.Visibility` (TRANSPARENCY-001): this module only assembles
  what the repo's configured level admits.
  """

  import Ecto.Query

  alias OpenAgents.Changelog.Entry
  alias OpenAgents.Forge.{BuildReceipt, DeployReceipt, PushReceipt, Visibility}
  alias OpenAgents.Repo
  alias OpenAgents.Transparency
  alias OpenAgents.Transparency.ArtifactLink

  @schema_version "openagents.changelog.v1"
  @cache_key {__MODULE__, :cache}
  @cache_ttl_ms 5_000
  @entry_limit 200
  @receipt_scan 500

  @doc "The API schema version."
  def schema_version, do: @schema_version

  @doc """
  The bounded public timeline for `repo`, newest first. Returns
  `{:error, :not_public}` unless the repo's visibility level admits the
  ledger. Pass `refresh: true` to bypass the cache (PubSub-driven callers).
  """
  def timeline(repo, opts \\ []) do
    viewer = opts[:viewer]

    cond do
      not Visibility.allows?(repo, :ledger) ->
        {:error, :not_public}

      opts[:refresh] ->
        rows = build(repo, viewer)
        if is_nil(viewer), do: put_cache(repo, rows)
        {:ok, rows}

      true ->
        {:ok, cached(repo, viewer)}
    end
  end

  @doc "The `/api/changelog` payload (schema-versioned superset of the page)."
  def projection(repo, opts \\ []) do
    case timeline(repo, opts) do
      {:ok, rows} ->
        {:ok,
         %{
           "schema" => @schema_version,
           "repo" => repo,
           "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
           "entries" => Enum.map(rows, &api_row/1)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Insert one authored entry (used by backfill now; jobs/operators later)."
  def record(attrs) do
    case %Entry{}
         |> Entry.changeset(attrs)
         |> Repo.insert(on_conflict: :nothing, conflict_target: [:repo, :sha, :source]) do
      {:ok, %Entry{repo: repo} = entry} ->
        broadcast_entry(repo)
        {:ok, entry}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # ── announcement ─────────────────────────────────────────────────────────

  @entries_topic "changelog:entries"

  # The forge receipts that produce the ledger's agent-layer rows. A receipted
  # deploy nobody wrote a note for is still a row, so a rail that listened only
  # for authored entries would miss every deploy.
  @forge_topics ["forge:pushes", "forge:target", "forge:builds", "forge:deploys"]

  @ledger_events [
    :changelog_entry,
    :forge_push,
    :forge_target,
    :forge_target_status,
    :forge_build_ready,
    :forge_deploy
  ]

  @doc """
  Subscribes the caller to everything that can move the ledger: authored
  entries, and the forge receipts behind the agent-layer rows.

  The messages carry no rows. A subscriber re-reads through `timeline/2`, which
  applies the repo's own `OpenAgents.Forge.Visibility` level, so a subscriber
  can never be handed a row the projection would have withheld.
  """
  def subscribe do
    :ok = Phoenix.PubSub.subscribe(OpenAgents.PubSub, @entries_topic)
    Enum.each(@forge_topics, &(:ok = Phoenix.PubSub.subscribe(OpenAgents.PubSub, &1)))
  end

  @doc """
  Whether a received message means the ledger moved.

  Subscribers match on this rather than on a list of forge topics of their own,
  so the set of things that move the changelog is stated once, here, beside the
  projection that reads them.
  """
  def ledger_event?(message) when is_tuple(message) and tuple_size(message) > 0,
    do: elem(message, 0) in @ledger_events

  def ledger_event?(_message), do: false

  @doc """
  Announces an appended entry, after dropping the cached projection.

  The cache is what a reconnecting client reads on its next mount, so leaving
  it in place would let a page that dropped and came back show the ledger as it
  was for up to the TTL.
  """
  def broadcast_entry(repo) when is_binary(repo) do
    :persistent_term.erase(@cache_key)

    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      @entries_topic,
      {:changelog_entry, repo}
    )
  end

  # ── assembly ─────────────────────────────────────────────────────────────

  defp cached(repo, viewer) do
    if is_nil(viewer) do
      now = System.monotonic_time(:millisecond)

      case :persistent_term.get(@cache_key, nil) do
        {^repo, at, rows} when now - at < @cache_ttl_ms -> rows
        _ -> put_cache(repo, build(repo, nil))
      end
    else
      build(repo, viewer)
    end
  end

  defp put_cache(repo, rows) do
    :persistent_term.put(@cache_key, {repo, System.monotonic_time(:millisecond), rows})
    rows
  end

  defp build(repo, viewer) do
    entries = safely(fn -> authored_entries(repo) end, [])
    receipts = safely(fn -> receipt_index(repo) end, %{pushes: [], builds: [], deploys: []})

    authored = Enum.map(entries, &entry_row(&1, receipts))
    covered = entries |> Enum.map(& &1.sha) |> MapSet.new()

    uncovered =
      receipts.deploys
      |> Enum.reject(fn deploy -> Enum.any?(covered, &sha_match?(&1, deploy.sha)) end)
      |> Enum.map(&deploy_row(&1, receipts))

    (authored ++ uncovered)
    |> Enum.sort_by(& &1.entry_at, {:desc, DateTime})
    |> Enum.take(@entry_limit)
    |> redact_rows(viewer)
  end

  defp redact_rows(rows, viewer) do
    link_ids =
      rows
      |> Enum.map(& &1[:artifact_link_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    by_id =
      if link_ids == [] do
        %{}
      else
        ArtifactLink
        |> where([l], l.id in ^link_ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      end

    Enum.map(rows, fn row ->
      link = row[:artifact_link_id] && Map.get(by_id, row[:artifact_link_id])
      Transparency.redact_for_viewer(row, link, viewer)
    end)
  end

  defp authored_entries(repo) do
    Entry
    |> where([e], e.repo == ^repo)
    |> order_by([e], desc: e.entry_at)
    |> limit(@entry_limit)
    |> Repo.all()
  end

  defp receipt_index(repo) do
    %{
      pushes:
        PushReceipt
        |> where([r], r.repo == ^repo)
        |> order_by([r], desc: r.wal_seq)
        |> limit(@receipt_scan)
        |> Repo.all(),
      builds:
        BuildReceipt
        |> where([r], r.repo == ^repo)
        |> order_by([r], desc: r.inserted_at)
        |> limit(@receipt_scan)
        |> Repo.all(),
      deploys:
        DeployReceipt
        |> where([r], r.repo == ^repo)
        |> order_by([r], desc: r.inserted_at)
        |> limit(@receipt_scan)
        |> Repo.all()
    }
  end

  defp entry_row(%Entry{} = entry, receipts) do
    embargoed = embargoed?(entry)
    deploy = find_by_sha(receipts.deploys, entry.sha)
    build = find_by_sha(receipts.builds, entry.sha)
    push = find_push(receipts.pushes, entry.sha)

    %{
      kind: :entry,
      repo: entry.repo,
      sha: if(embargoed, do: nil, else: entry.sha),
      short_sha: if(embargoed, do: nil, else: short(entry.sha)),
      summary: entry.summary,
      category: entry.category,
      source: entry.source,
      visibility: entry.visibility,
      entry_at: entry.entry_at,
      artifact_link_id: entry.artifact_link_id,
      transparency_tier: entry.transparency_tier,
      detail: if(embargoed, do: %{}, else: entry.detail || %{}),
      trace_ref: entry.trace_ref,
      trace_digest: entry.trace_digest,
      deploy: deploy && deploy_facts(deploy),
      build: build && build_facts(build),
      push: push && push_facts(push),
      receipt_ids: %{
        push: entry.push_receipt_id || (push && push.id),
        build: entry.build_receipt_id || (build && build.id),
        deploy: entry.deploy_receipt_id || (deploy && deploy.id)
      }
    }
  end

  defp deploy_row(%DeployReceipt{} = deploy, receipts) do
    build = find_by_sha(receipts.builds, deploy.sha)
    push = find_push(receipts.pushes, deploy.sha)

    %{
      kind: :receipt,
      repo: deploy.repo,
      sha: deploy.sha,
      short_sha: short(deploy.sha),
      summary: nil,
      category: "forge",
      source: "receipt",
      visibility: "l2",
      entry_at: deploy.inserted_at,
      artifact_link_id: nil,
      transparency_tier: nil,
      detail: %{},
      trace_ref: nil,
      trace_digest: nil,
      deploy: deploy_facts(deploy),
      build: build && build_facts(build),
      push: push && push_facts(push),
      receipt_ids: %{push: push && push.id, build: build && build.id, deploy: deploy.id}
    }
  end

  defp deploy_facts(deploy) do
    %{
      result: deploy.result,
      push_to_live_ms: deploy.push_to_live_ms,
      modules: length(deploy.modules || []),
      nodes: length(deploy.nodes || []),
      canary: deploy.canary
    }
  end

  defp build_facts(build) do
    %{duration_ms: build.duration_ms, modules: length(build.modules || [])}
  end

  # The push principal is "kind:id"; only the role prefix is ever published.
  defp push_facts(push) do
    %{wal_seq: push.wal_seq, principal_role: push.principal |> to_string() |> role_of()}
  end

  defp role_of(principal), do: principal |> String.split(":", parts: 2) |> hd()

  defp embargoed?(%Entry{visibility: "l1"} = entry) do
    case entry.disclosure_after do
      nil -> true
      at -> DateTime.compare(DateTime.utc_now(), at) == :lt
    end
  end

  defp embargoed?(_entry), do: false

  defp find_by_sha(receipts, sha), do: Enum.find(receipts, &sha_match?(sha, &1.sha))

  defp find_push(pushes, sha) do
    Enum.find(pushes, fn push ->
      push.refs
      |> Map.values()
      |> Enum.any?(fn
        %{"new" => new} -> sha_match?(sha, new)
        new when is_binary(new) -> sha_match?(sha, new)
        _ -> false
      end)
    end)
  end

  # Entries may carry short shas (backfill) while receipts carry full ones,
  # and vice versa — prefix-match in both directions, minimum 7 chars.
  defp sha_match?(a, b) when is_binary(a) and is_binary(b) do
    min(byte_size(a), byte_size(b)) >= 7 and
      (String.starts_with?(a, b) or String.starts_with?(b, a))
  end

  defp sha_match?(_a, _b), do: false

  defp short(nil), do: nil
  defp short(sha), do: String.slice(sha, 0, 12)

  defp api_row(row) do
    %{
      "kind" => to_string(row.kind),
      "sha" => row.sha,
      "short_sha" => row.short_sha,
      "summary" => row.summary,
      "category" => row.category,
      "source" => row.source,
      "visibility" => row.visibility,
      "entry_at" => row.entry_at && DateTime.to_iso8601(row.entry_at),
      "detail" => row.detail,
      "trace_ref" => row.trace_ref,
      "trace_digest" => row.trace_digest,
      "deploy" => row.deploy && stringify(row.deploy),
      "build" => row.build && stringify(row.build),
      "push" => row.push && stringify(row.push),
      "receipt_ids" => stringify(row.receipt_ids),
      "commit_url" => row.sha && commit_url(row)
    }
  end

  defp commit_url(row) do
    base = Visibility.repo_path(row.repo)
    base <> "/commit/" <> row.short_sha
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp safely(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end
end
