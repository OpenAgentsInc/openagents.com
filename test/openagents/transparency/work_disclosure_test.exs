defmodule OpenAgents.Transparency.WorkDisclosureTest do
  @moduledoc """
  Stage 5 of `#10`: transparency tiers over work in progress.

  Three properties, and the first is the one that makes the other two mean
  anything.

  **The schedule is exhaustive.** Every column of `forge_assignments`,
  `work_jobs`, `issue_evidence`, and `traces` is either the source of exactly
  one scheduled field or a member of that family's never list. A new column is
  a failure here until somebody decides which, so the schedule cannot quietly
  fall behind the schema it describes.

  **The rungs discriminate on a repository nothing else gates.** Every tier
  assertion below runs on a *public* repository, where
  `Repositories.readable_by/2` admits everybody and the tier is the only thing
  between an anonymous reader and a branch, a revision, a receipt handle, an
  environment, and a report. A private repository would have proved the tier
  worked when the repository gate was doing the work.

  **Repository authority is still stronger.** A record whose tier is `glass`
  in a repository that went private is invisible to a non-member. That case is
  the one the disclosure dial does not cover and the tier cannot override.
  """
  use OpenAgents.DataCase, async: true

  import Ecto.Query
  import OpenAgents.AccountsFixtures

  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{Evidence, EvidenceEntry}
  alias OpenAgents.Forge.Assignments
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Transparency
  alias OpenAgents.Traces.Trace
  alias OpenAgents.Transparency.{ArtifactLink, WorkDisclosure}
  alias OpenAgents.Work.Job

  @sha String.duplicate("ab", 20)

  setup do
    owner = repository_user_fixture("work-owner")
    member = repository_user_fixture("work-member")
    stranger = repository_user_fixture("work-stranger")

    repository = repository_with_member_fixture(owner, %{visibility: "public"}, "owner")
    {:ok, _} = Repositories.add_member(repository, member, "maintainer")

    {:ok, issue} = Issues.create_issue(repository, %{title: "Do the work"})

    %{
      owner: owner,
      member: member,
      stranger: stranger,
      repository: repository,
      issue: issue
    }
  end

  # ── the schedule is exhaustive ──────────────────────────────────────────

  describe "the schedule covers every column of every record it describes" do
    @schema_for %{
      attempt: Assignment,
      work_job: Job,
      evidence: EvidenceEntry,
      trace: Trace
    }

    for {family, schema} <- @schema_for do
      test "#{family}: every column is scheduled or in the never list" do
        family = unquote(family)
        schema = unquote(schema)

        columns = MapSet.new(schema.__schema__(:fields))
        scheduled = MapSet.new(WorkDisclosure.source_columns(family))
        never = MapSet.new(WorkDisclosure.never(family))

        unclassified = columns |> MapSet.difference(scheduled) |> MapSet.difference(never)

        assert MapSet.to_list(unclassified) == [],
               "#{family} columns in neither the schedule nor the never list: " <>
                 inspect(MapSet.to_list(unclassified))

        both = MapSet.intersection(scheduled, never)

        assert MapSet.to_list(both) == [],
               "#{family} columns both scheduled and never: " <> inspect(MapSet.to_list(both))
      end
    end

    test "every scheduled field names a real tier, and the ladder is monotone" do
      for family <- WorkDisclosure.families() do
        for {field, tier} <- WorkDisclosure.schedule()[family] do
          assert tier in [:pulse, :ledger, :glass],
                 "#{family}.#{field} is on no rung this ladder has"
        end

        assert WorkDisclosure.fields_at(family, :dark) == []

        pulse = MapSet.new(WorkDisclosure.fields_at(family, :pulse))
        ledger = MapSet.new(WorkDisclosure.fields_at(family, :ledger))
        glass = MapSet.new(WorkDisclosure.fields_at(family, :glass))

        assert MapSet.subset?(pulse, ledger)
        assert MapSet.subset?(ledger, glass)
      end
    end

    test "the work vocabulary is in the artifact type list and `trace` has no producer" do
      types = ArtifactLink.artifact_types()

      for member <- ~w(attempt work_job deployment trace) do
        assert member in types
      end

      # `#149` asks for a `trace` member and nothing in this repository
      # produces a trace artifact. Naming that here keeps the vocabulary from
      # reading as a shipped surface.
      producing =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(&Regex.scan(~r/artifact_type:\s*"(\w+)"/, File.read!(&1)))
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.uniq()

      refute "trace" in producing
      assert "attempt" in producing
    end
  end

  # ── the rungs, on a public repository ───────────────────────────────────

  describe "an attempt on a public repository" do
    test "tells an anonymous reader that work ran, and no ref, revision, or reason",
         context do
      attempt(context, %{state: "completed", terminal_commit: @sha})

      assert [projection] = read_attempts(context, nil)

      assert Enum.sort(Map.keys(projection)) ==
               Enum.sort([:work_job | WorkDisclosure.fields_at(:attempt, :pulse)])

      assert projection.state == "completed"
      assert projection.target_kind == "box"
      assert projection.requester_kind == "user"

      refute Map.has_key?(projection, :branch)
      refute Map.has_key?(projection, :terminal_branch)
      refute Map.has_key?(projection, :terminal_commit)
      refute Map.has_key?(projection, :failure_reason)
    end

    test "gives a signed-in stranger exactly what it gives anonymous traffic", context do
      attempt(context, %{state: "completed", terminal_commit: @sha})

      assert read_attempts(context, nil) == read_attempts(context, context.stranger)
    end

    test "gives a repository member the branch, the revision, and the reason", context do
      attempt(context, %{state: "failed", failure_reason: "assignment_expired"})

      assert [projection] = read_attempts(context, context.member)

      assert Enum.sort(Map.keys(projection)) ==
               Enum.sort([:work_job | WorkDisclosure.fields_at(:attempt, :ledger)])

      assert projection.branch == "agent/issue-1"
      assert projection.failure_reason == "assignment_expired"
    end

    test "never publishes the requesting principal, only its kind", context do
      %{assignment: assignment} = attempt(context, %{})

      for reader <- [nil, context.stranger, context.member, context.owner] do
        assert [projection] = read_attempts(context, reader)
        assert projection.requester_kind in ["user", "agent"]

        values = projection |> Map.values() |> Enum.map(&inspect/1) |> Enum.join(" ")
        refute values =~ assignment.requesting_principal["id"]
        refute values =~ "actor_id"
      end
    end
  end

  describe "the work job behind an attempt" do
    test "reaches a member as counts and bounds, and never as a report", context do
      attempt(context, %{}, job: true)

      assert [%{work_job: job}] = read_attempts(context, context.member)

      assert Enum.sort(Map.keys(job)) == Enum.sort(WorkDisclosure.fields_at(:work_job, :ledger))

      assert job.tool_call_count == 7
      assert job.budget == %{"wall_clock_ms" => 60_000, "maximum_report_bytes" => 8_000}

      refute Map.has_key?(job, :report)
      refute Map.has_key?(job, :usage)
      refute Map.has_key?(job, :model_id)
    end

    test "reaches the account the work belongs to as its report", context do
      attempt(context, %{}, job: true)

      assert [%{work_job: job}] = read_attempts(context, context.owner)

      assert Enum.sort(Map.keys(job)) == Enum.sort(WorkDisclosure.fields_at(:work_job, :glass))
      assert job.report == "Renamed the billing column and pushed."
      assert job.model_id == "test-model"
    end

    test "never publishes the goal, the prompt, or the authority snapshot", context do
      attempt(context, %{}, job: true)

      for reader <- [nil, context.stranger, context.member, context.owner] do
        assert [%{work_job: job}] = read_attempts(context, reader)

        rendered = inspect(job)
        refute rendered =~ "SECRET-GOAL"
        refute rendered =~ "SECRET-PROMPT"
        refute rendered =~ "/private/checkout"
        refute Map.has_key?(job, :goal)
        refute Map.has_key?(job, :delegation)
        refute Map.has_key?(job, :authority_snapshot)
        refute Map.has_key?(job, :budget_snapshot)
      end
    end

    test "an attempt with no job carries no job", context do
      attempt(context, %{})

      assert [%{work_job: nil}] = read_attempts(context, context.owner)
    end
  end

  describe "an evidence edge on a public repository" do
    test "says restricted evidence exists without naming the revision, receipt, or place",
         context do
      evidence(context, %{
        family: "deployment",
        plane: "tenant",
        environment: "acme-production",
        result: "succeeded"
      })

      assert [projection] = read_evidence(context, nil)

      assert Enum.sort(Map.keys(projection)) ==
               Enum.sort(WorkDisclosure.fields_at(:evidence, :pulse))

      assert projection.family == "deployment"
      assert projection.result == "succeeded"
      assert projection.plane == "tenant"

      refute Map.has_key?(projection, :commit)
      refute Map.has_key?(projection, :receipt_id)
      refute Map.has_key?(projection, :environment)
    end

    test "gives a member the revision, the receipt handle, and the environment", context do
      evidence(context, %{
        family: "deployment",
        plane: "tenant",
        environment: "acme-production",
        result: "succeeded"
      })

      assert [projection] = read_evidence(context, context.member)

      assert Enum.sort(Map.keys(projection)) ==
               Enum.sort(WorkDisclosure.fields_at(:evidence, :ledger))

      assert projection.commit == @sha
      assert projection.environment == "acme-production"
    end

    test "never publishes the actor at any rung", context do
      evidence(context, %{actor: "user:0e1c1a1e-secret"})

      for reader <- [nil, context.stranger, context.member, context.owner] do
        assert [projection] = read_evidence(context, reader)
        refute Map.has_key?(projection, :actor)
        refute inspect(projection) =~ "0e1c1a1e-secret"
      end
    end

    test "inherits the attempt's link, so revoking the attempt takes its receipts",
         context do
      %{assignment: assignment} = attempt(context, %{terminal_commit: @sha})

      # The edge is written by the production path, not fabricated here.
      # `bind_attempt/1` sweeps the receipt chain for the revision the attempt
      # reported and records what it finds, which is the only route by which an
      # edge carries an `assignment_id` at all.
      build_receipt(context, @sha, "complete")

      assert [edge] = Evidence.bind_attempt(assignment)
      assert edge.assignment_id == assignment.id
      assert edge.artifact_link_id == assignment.artifact_link_id

      assert [_projection] = read_evidence(context, context.member)

      revoke(assignment.artifact_link_id)

      assert read_evidence(context, context.member) == []
      assert read_attempts(context, context.member) == []
    end
  end

  # ── revocation ──────────────────────────────────────────────────────────

  describe "revoking an attempt's link" do
    test "removes the attempt from every reader, including its own account", context do
      %{assignment: assignment} = attempt(context, %{}, job: true)

      assert [_] = read_attempts(context, context.owner)

      revoke(assignment.artifact_link_id)

      for reader <- [nil, context.stranger, context.member, context.owner] do
        assert read_attempts(context, reader) == []
      end
    end

    test "leaves an auditable tombstone on the link", context do
      %{assignment: assignment} = attempt(context, %{})

      revoke(assignment.artifact_link_id)

      link = Repo.get!(ArtifactLink, assignment.artifact_link_id)

      assert link.revoked_at
      assert link.revocation_tombstone["reason"] == "owner_withdrew_consent"
      assert link.revocation_tombstone["revoked_at"]
      assert Transparency.effective_tier(link, %{tier: :glass, admin: true}) == :dark
    end
  end

  # ── repository authority is stronger than any tier ──────────────────────

  describe "repository authority" do
    test "a glass record in a repository that went private is invisible to a non-member",
         context do
      %{assignment: assignment} = attempt(context, %{terminal_commit: @sha}, job: true)

      # The strongest possible tier: the link and the row both say `glass`, so
      # nothing in the disclosure ladder is withholding anything.
      Repo.update_all(from(l in ArtifactLink, where: l.id == ^assignment.artifact_link_id),
        set: [tier: "glass"]
      )

      Repo.update_all(from(a in Assignment, where: a.id == ^assignment.id),
        set: [transparency_tier: "glass"]
      )

      assert [_] = read_attempts(context, nil)

      {1, _} =
        Repo.update_all(
          from(r in OpenAgents.Repositories.Repository, where: r.id == ^context.repository.id),
          set: [visibility: "private"]
        )

      assert_raise Ecto.NoResultsError, fn ->
        Repositories.get_visible_by_path!(
          context.repository.owner,
          context.repository.name,
          nil
        )
      end

      assert_raise Ecto.NoResultsError, fn ->
        Repositories.get_visible_by_path!(
          context.repository.owner,
          context.repository.name,
          context.stranger
        )
      end
    end
  end

  # ── the viewer ladder ───────────────────────────────────────────────────

  describe "the viewer descriptor" do
    test "puts an operator at glass, a member at ledger, and everyone else at pulse",
         context do
      operator = admin_user()

      assert WorkDisclosure.viewer(context.repository, operator).tier == :glass
      assert WorkDisclosure.viewer(context.repository, context.member).tier == :ledger
      assert WorkDisclosure.viewer(context.repository, context.owner).tier == :ledger
      assert WorkDisclosure.viewer(context.repository, context.stranger).tier == :pulse
      assert WorkDisclosure.viewer(context.repository, nil).tier == :pulse
      assert WorkDisclosure.viewer(context.repository, nil).account_id == nil
    end

    test "an agent-requested attempt has no link, and only an operator reaches glass",
         context do
      attempt(context, %{}, job: true, link: false)

      assert [%{work_job: operator_job}] = read_attempts(context, admin_user())
      assert Map.has_key?(operator_job, :report)

      # Nobody owns an attempt an agent requested, so nobody but an operator is
      # raised. The account that would have owned a user-requested attempt
      # reads it at `ledger` like any other member.
      assert [%{work_job: owner_job}] = read_attempts(context, context.owner)
      refute Map.has_key?(owner_job, :report)

      assert [projection] = read_attempts(context, nil)
      assert projection.requester_kind == "agent"
      refute Map.has_key?(projection, :branch)
    end

    test "an operator reads an attempt at glass without owning it", context do
      attempt(context, %{}, job: true)

      assert [%{work_job: job}] = read_attempts(context, admin_user())
      assert Map.has_key?(job, :report)
    end
  end

  # ── the attempt link is minted where the attempt is ─────────────────────

  describe "the attempt link" do
    test "is minted for a user-requested attempt", context do
      assert {:ok, link} =
               WorkDisclosure.link_for_attempt(
                 context.repository,
                 %{"type" => "user", "id" => context.owner.id},
                 %{"branch" => "agent/issue-1"}
               )

      assert link.artifact_type == "attempt"
      assert link.artifact_ref == "id"
      assert link.tier == "ledger"
      assert link.account_id == context.owner.id
    end

    test "is not minted for an agent-requested attempt", context do
      assert :none ==
               WorkDisclosure.link_for_attempt(
                 context.repository,
                 %{"type" => "agent", "id" => Ecto.UUID.generate()},
                 %{}
               )
    end

    test "is what `Assignments.create/1` stores on the attempt it persists", context do
      {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(context.owner)

      {:ok, box} =
        %OpenAgents.Box.ConversationBox{}
        |> OpenAgents.Box.ConversationBox.changeset(%{
          conversation_id: conversation.id,
          box_id: "bx_work_disclosure",
          state: "ready",
          setup_status: "done"
        })
        |> Repo.insert()

      # The run never starts in a test, and it does not need to: the assignment
      # and its link are committed by `persist_assignment/7` before
      # `start_target/7` is reached, so the row this reads is the row the
      # production path writes.
      result =
        try do
          Assignments.create(%{
            "target_kind" => "box",
            "box_id" => box.box_id,
            "conversation_id" => conversation.id,
            "repository_id" => context.repository.id,
            "issue_number" => context.issue.number,
            "branch" => "agent/created",
            "requesting_user" => context.owner,
            "requesting_principal" => context.owner
          })
        rescue
          # The box never starts here, and `start_target/7` records that as a
          # terminal failure. Whatever it returns, the assignment and its link
          # were committed by `persist_assignment/7` first, which is the row
          # this test is about.
          error -> {:error, error}
        end

      assignment =
        case Repo.one(from a in Assignment, where: a.issue_id == ^context.issue.id, limit: 1) do
          nil -> flunk("no assignment persisted: #{inspect(result)}")
          row -> row
        end

      assert assignment.artifact_link_id
      assert assignment.transparency_tier == "ledger"

      link = Repo.get!(ArtifactLink, assignment.artifact_link_id)
      assert link.account_id == context.owner.id
      assert link.artifact_type == "attempt"
    end
  end

  # ── the same viewer, the same answer, on every surface ──────────────────

  describe "one schedule, read from one place" do
    test "every caller of a work projection outside its own context passes a viewer" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(
          &(&1 in [
              "lib/openagents/forge/assignments.ex",
              "lib/openagents/issues/evidence.ex"
            ])
        )
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> then(
            &Regex.scan(
              ~r/(?:Assignments\.attempts_for_issues?|Evidence\.for_issues?|attempt_summary|Evidence\.summary)\(([\s\S]{0,260})/,
              &1
            )
          )
          |> Enum.reject(fn [_whole, args] -> String.contains?(args, "viewer") end)
          |> Enum.map(fn [whole, _args] -> "#{path}: #{String.slice(whole, 0, 60)}" end)
        end)

      assert offenders == [],
             "a work projection read without a viewer runs at the unclamped default: " <>
               Enum.join(offenders, "\n")
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp read_attempts(context, reader),
    do: Assignments.attempts_for_issue(context.issue, viewer(context, reader))

  defp read_evidence(context, reader),
    do: Evidence.for_issue(context.issue, viewer(context, reader))

  defp viewer(context, reader), do: WorkDisclosure.viewer(context.repository, reader)

  defp attempt(context, attrs, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    principal =
      if Keyword.get(opts, :link, true) do
        %{
          "type" => "user",
          "id" => context.owner.id,
          "actor_type" => "user",
          "actor_id" => context.owner.id
        }
      else
        agent = Ecto.UUID.generate()
        %{"type" => "agent", "id" => agent, "actor_type" => "agent", "actor_id" => agent}
      end

    link =
      case WorkDisclosure.link_for_attempt(context.repository, principal, %{
             "branch" => "agent/issue-1"
           }) do
        {:ok, link} -> link
        :none -> nil
      end

    job = if opts[:job], do: work_job(context), else: nil

    assignment =
      %Assignment{}
      |> Assignment.changeset(
        Map.merge(
          %{
            conversation_box_id: box(context).id,
            target_kind: "box",
            repository_id: context.repository.id,
            issue_id: context.issue.id,
            requesting_principal: principal,
            branch: "agent/issue-1",
            deadline_at: DateTime.add(now, 600, :second),
            admitted_at: now,
            started_at: now,
            finished_at: now,
            work_job_id: job && job.id,
            artifact_link_id: link && link.id
          },
          attrs
        )
      )
      |> Repo.insert!()

    %{assignment: assignment, link: link, job: job}
  end

  defp box(context) do
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(context.owner)

    {:ok, box} =
      %OpenAgents.Box.ConversationBox{}
      |> OpenAgents.Box.ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_wd_#{System.unique_integer([:positive])}",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert()

    box
  end

  defp work_job(context) do
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(context.owner)
    visitor = Repo.get_by!(OpenAgents.Conversations.Visitor, user_id: context.owner.id)

    %Job{}
    |> Job.create_changeset(%{
      conversation_id: conversation.id,
      owner_visitor_id: visitor.id,
      surface: "text",
      kind: "coding",
      goal: "SECRET-GOAL rename the billing column",
      context_hint: "SECRET-PROMPT the private schema",
      authority_snapshot: %{"roots" => ["/private/checkout"], "cwd" => "/private/checkout"},
      budget_snapshot: %{"wall_clock_ms" => 60_000, "maximum_report_bytes" => 8_000}
    })
    |> Repo.insert!()
    |> Job.lifecycle_changeset(%{status: "running", started_at: DateTime.utc_now()})
    |> Repo.update!()
    |> Job.lifecycle_changeset(%{
      status: "completed",
      report: "Renamed the billing column and pushed.",
      model_id: "test-model",
      tool_call_count: 7,
      continuation_count: 1,
      usage: %{"input_tokens" => 100},
      started_at: DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp evidence(context, attrs) do
    defaults = %{
      repository_id: context.repository.id,
      issue_id: context.issue.id,
      commit_sha: @sha,
      family: "build",
      receipt_id: Ecto.UUID.generate(),
      plane: "forge",
      result: "complete",
      actor: "user:someone",
      source: "closing_reference"
    }

    attrs = Map.merge(defaults, attrs)

    %EvidenceEntry{}
    |> EvidenceEntry.changeset(attrs)
    |> Repo.insert!()
  end

  defp build_receipt(context, sha, status) do
    %OpenAgents.Forge.BuildReceipt{}
    |> OpenAgents.Forge.BuildReceipt.start_changeset(%{
      repo: context.repository.storage_key,
      repository_id: context.repository.id,
      sha: sha,
      target_id: Ecto.UUID.generate()
    })
    |> Ecto.Changeset.put_change(:status, status)
    |> Repo.insert!()
  end

  defp revoke(link_id) do
    ArtifactLink
    |> Repo.get!(link_id)
    |> Transparency.revoke("owner_withdrew_consent", Ecto.UUID.generate())
    |> Repo.update!()
  end

  # The owner's GitHub id is unioned into the operator list in
  # `OpenAgents.Accounts` itself rather than read from configuration, so this
  # needs no global state and stays safe to run concurrently.
  defp admin_user do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: 14_167_547,
        github_login: "work-operator",
        github_avatar_url: "https://avatars.githubusercontent.com/u/14167547?v=4"
      })

    true = OpenAgents.Accounts.admin?(user)
    user
  end
end
