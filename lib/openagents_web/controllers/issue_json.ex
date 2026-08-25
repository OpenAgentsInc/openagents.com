defmodule OpenAgentsWeb.IssueJSON do
  @moduledoc """
  Renders GitHub-compatible issue JSON.

  GitHub-shaped keys keep their exact shape. OpenAgents-specific fields live
  under one `openagents` object, so a GitHub client sees an additional object
  and nothing else.

  `pull_request` is the one addition that is not namespaced, because it is not
  ours. GitHub's issues API returns both issues and pull requests and marks the
  latter with a `pull_request` object; a client that already reads GitHub knows
  to look for that key, and inventing `openagents.pull_request` beside it would
  make the compatible reading the wrong one. The `?type=` filter that lists one
  kind without the other has no GitHub counterpart, so it stays in the
  extension namespace where the root document can publish it. Each field appears only when the caller supplies it, and
  the object appears only when at least one field does: an absent dependency
  graph is not the same fact as an issue with no prerequisites, and an absent
  progress derivation is not the same fact as an issue nobody has started.

  The `work` array is the read-only issue-to-job linkage: one entry per
  recorded execution attempt, projected from `forge_assignments`. The issue
  stays the requested outcome and never becomes a second work record.

  Every key this module can put inside the object is enumerated at
  `GET /api/v1`, and `OpenAgentsWeb.ApiExtensionGovernanceTest` fails if one
  is not.
  """

  def render("index.json", %{issues: issues, pagination: pagination} = assigns) do
    %{
      issues: Enum.map(issues, &issue_json(&1, assigns)),
      pagination: %{
        page: pagination.page,
        per_page: pagination.per_page,
        total: pagination.total,
        total_pages: total_pages(pagination.total, pagination.per_page)
      }
    }
  end

  def render("show.json", %{issue: issue} = assigns) do
    issue_json(issue, assigns)
  end

  def render("activity.json", %{activity: activity} = assigns) do
    url_base = url_base(assigns)

    %{
      threads: Enum.map(activity.threads, &thread_json(&1, url_base)),
      receipts: Enum.map(activity.receipts, &receipt_json/1),
      releases: releases_json(Map.get(activity, :releases))
    }
  end

  # The release half of the activity answer. `receipts` matches a receipt to
  # the exact commit; this says which release revision contains that commit,
  # which is the question "did this ship" actually asks.
  defp releases_json(nil), do: releases_json(OpenAgents.Issues.Releases.empty())

  defp releases_json(releases) do
    %{
      commits:
        Enum.map(releases.commits, fn commit ->
          %{
            sha: commit.sha,
            verb: commit.verb,
            referenced_at: commit.referenced_at,
            releases: Enum.map(commit.releases, &release_json/1)
          }
        end),
      released_in: release_json(releases.released_in),
      truncated: releases.truncated
    }
  end

  defp release_json(nil), do: nil

  defp release_json(release) do
    %{
      id: release.id,
      sha: release.sha,
      status: release.status,
      promoted_at: release.promoted_at,
      settled_at: release.settled_at
    }
  end

  defp issue_json(issue, assigns) do
    owner = Map.get(assigns, :owner, "OpenAgents")
    repo = Map.get(assigns, :repo, "openagents")
    url_base = url_base(assigns)

    %{
      id: issue.id,
      node_id: "I_#{issue.id}",
      number: issue.number,
      title: issue.title,
      body: issue.body,
      state: issue.state,
      state_reason: issue.state_reason,
      locked: issue.locked,
      comments: issue.comments,
      labels: issue.labels || [],
      assignees: issue.assignees || [],
      milestone: issue.milestone,
      user: issue.user,
      created_at: issue.inserted_at,
      updated_at: issue.updated_at,
      closed_at: issue.closed_at,
      html_url: "#{url_base}/#{owner}/#{repo}/issues/#{issue.number}",
      url: "#{url_base}/api/v1/repos/#{owner}/#{repo}/issues/#{issue.number}"
    }
    |> put_pull_request(issue, assigns, owner, repo, url_base)
    |> put_extension(issue, assigns)
  end

  # GitHub's marker for an issue row that is a pull request. Absent on a plain
  # issue and present on a pull request, exactly as GitHub does it: the key's
  # presence is the fact, so a client tests for it rather than reading it.
  # `draft` joins it at the top level for the same reason -- that is where
  # GitHub puts it on a pull-request-backed issue.
  #
  # `diff_url` and `patch_url` are GitHub keys this forge has no route for. An
  # advertised URL that answers 404 is worse than an absent one, so they are
  # omitted until those routes exist.
  defp put_pull_request(json, issue, assigns, owner, repo, url_base) do
    case assigns |> Map.get(:pull_requests, %{}) |> Map.get(issue.id) do
      nil ->
        json

      marker ->
        json
        |> Map.put(:draft, marker.draft)
        |> Map.put(:pull_request, %{
          url: "#{url_base}/api/v1/repos/#{owner}/#{repo}/pulls/#{issue.number}",
          html_url: "#{url_base}/#{owner}/#{repo}/pulls/#{issue.number}",
          merged_at: marker.merged_at
        })
    end
  end

  defp put_extension(json, issue, assigns) do
    url_base = url_base(assigns)

    extension =
      %{}
      |> put_dependencies(Map.get(assigns, :dependencies), issue)
      |> put_progress(Map.get(assigns, :progress), issue)
      |> put_work(Map.get(assigns, :work), issue)
      |> put_threads(Map.get(assigns, :threads), issue, url_base)
      |> put_evidence(Map.get(assigns, :evidence), issue)
      |> put_completion_claims(Map.get(assigns, :completion_claims), issue)

    if extension == %{}, do: json, else: Map.put(json, :openagents, extension)
  end

  defp put_dependencies(extension, nil, _issue), do: extension

  defp put_dependencies(extension, graph, issue) do
    dependencies = Map.get(graph, issue.id, %{blocked: false, blocked_by: [], blocks: []})

    Map.merge(extension, %{
      blocked: dependencies.blocked,
      blocked_by: dependencies.blocked_by,
      blocks: dependencies.blocks
    })
  end

  defp put_progress(extension, nil, _issue), do: extension

  defp put_progress(extension, progress, issue) when is_map(progress),
    do: Map.put(extension, :progress, Map.get(progress, issue.id, "to_do"))

  defp put_work(extension, nil, _issue), do: extension

  defp put_work(extension, attempts, issue) when is_map(attempts) do
    Map.put(extension, :work, attempts |> Map.get(issue.id, []) |> Enum.map(&attempt_json/1))
  end

  defp put_threads(extension, nil, _issue, _url_base), do: extension

  defp put_threads(extension, threads, issue, url_base) when is_map(threads) do
    Map.put(
      extension,
      :threads,
      threads |> Map.get(issue.id, []) |> Enum.map(&thread_json(&1, url_base))
    )
  end

  defp thread_json(thread, url_base) do
    %{
      id: thread.id,
      status: thread.status,
      visibility: thread.visibility,
      inserted_at: thread.inserted_at,
      updated_at: thread.updated_at,
      url: "#{url_base}/api/v1/threads/#{thread.id}"
    }
  end

  defp put_evidence(extension, nil, _issue), do: extension

  defp put_evidence(extension, evidence, issue) when is_map(evidence) do
    Map.put(extension, :evidence, evidence |> Map.get(issue.id, []) |> Enum.map(&evidence_json/1))
  end

  defp put_completion_claims(extension, nil, _issue), do: extension

  defp put_completion_claims(extension, claims, issue) when is_map(claims) do
    Map.put(
      extension,
      :completion_claims,
      claims |> Map.get(issue.id, []) |> Enum.map(&completion_claim_json/1)
    )
  end

  defp completion_claim_json(claim) do
    %{
      id: claim.id,
      revision: claim.revision,
      state: claim.state,
      reasons: claim.reasons,
      criteria: claim.criteria,
      verifier: claim.verifier,
      falsifier: claim.falsifier,
      closed: claim.closed,
      closed_at: claim.closed_at,
      closed_by_actor: claim.closed_by_actor,
      contradicted_at: claim.contradicted_at,
      contradiction_reason: claim.contradiction_reason,
      recorded_at: claim.recorded_at
    }
  end

  # The API renames two keys of the attempt projection and none of the
  # evidence projection, and adds nothing to either. Rendering exactly the keys
  # the projection returned is what keeps this from becoming a second
  # disclosure schedule: a tier that withheld `terminal_commit` produces a
  # response with no `commit` key at all rather than one carrying `null`, and a
  # field `OpenAgents.Transparency.WorkDisclosure` adds appears here without an
  # edit. `OpenAgentsWeb.IssueWorkDisclosureTest` reads both key sets from that
  # schedule, so a rename that loses a field fails.
  @attempt_key_names %{target_kind: :target, terminal_commit: :commit}

  defp evidence_json(entry), do: entry

  defp receipt_json(%{family: family, sha: sha, receipt: receipt}) do
    base =
      if is_struct(receipt) do
        receipt
        |> Map.from_struct()
        |> Map.delete(:__meta__)
      else
        receipt
      end

    base
    |> Map.put(:family, family)
    |> Map.put(:sha, sha)
  end

  defp attempt_json(attempt) do
    attempt
    |> Map.drop([:work_job])
    |> Map.new(fn {key, value} -> {Map.get(@attempt_key_names, key, key), value} end)
    |> put_attempt_work_job(attempt)
  end

  defp put_attempt_work_job(json, %{work_job: job}) when is_map(job),
    do: Map.put(json, :work_job, job)

  defp put_attempt_work_job(json, _attempt), do: json

  defp total_pages(0, _per_page), do: 1

  defp total_pages(total, per_page), do: ceil(total / per_page)

  defp url_base(assigns) do
    Map.get(assigns, :url_base) || String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")
  end
end
