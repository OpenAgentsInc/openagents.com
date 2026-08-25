defmodule OpenAgents.Issues.TraceDisclosureTest do
  @moduledoc """
  `#10`: the deliberate ATIF visibility policy for an issue.

  The decision under test is a refusal as much as a disclosure: **an issue
  publishes that a trajectory exists and never publishes one.** So the first
  property here is that no rung returns a step, and the rest is the two gates
  that decide whether even the existence is disclosed.

  Every tier assertion runs on a **public** repository, where
  `Repositories.readable_by/2` admits everybody and the two gates are the only
  things between an anonymous reader and a digest. A private repository would
  have proved the gates worked while the repository gate did the work — so the
  last test does exactly that case separately, and asserts that repository
  authority is still stronger than any consent.
  """
  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.{Assignment, Assignments}
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{Activity, TraceDisclosure}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Traces
  alias OpenAgents.Transparency.WorkDisclosure

  @document %{
    "schema_version" => "ATIF-v1.7",
    "session_id" => "s1",
    "steps" => [
      %{"step_id" => 1, "role" => "user", "message" => "the private prompt"},
      %{"step_id" => 2, "role" => "agent", "message" => "the private answer"},
      %{"step_id" => 3, "role" => "agent", "message" => "and a third"}
    ]
  }

  setup do
    owner = repository_user_fixture("trace-owner")
    member = repository_user_fixture("trace-member")
    stranger = repository_user_fixture("trace-stranger")

    repository = repository_with_member_fixture(owner, %{visibility: "public"}, "owner")
    {:ok, _} = Repositories.add_member(repository, member, "maintainer")

    {:ok, issue} = Issues.create_issue(repository, %{title: "Record the trajectory"})
    attempt = admit(owner, repository, issue)

    %{
      owner: owner,
      member: member,
      stranger: stranger,
      repository: repository,
      issue: issue,
      attempt: attempt
    }
  end

  describe "no rung publishes the trajectory" do
    test "the document is absent at every tier, for every reader", context do
      trace = upload(context.owner, context.attempt, "glass")

      for reader <- [nil, context.stranger, context.member, context.owner] do
        viewer = WorkDisclosure.viewer(context.repository, reader)
        projection = TraceDisclosure.project(trace, context.attempt, viewer)

        refute is_nil(projection),
               "expected a projection for #{inspect(reader && reader.github_login)}"

        refute Map.has_key?(projection, :document)
        refute Map.has_key?(projection, :steps)

        # Nothing anywhere in the projection restates a step, however nested.
        refute inspect(projection) =~ "the private prompt"
        refute inspect(projection) =~ "the private answer"
      end
    end

    test "the schedule itself refuses the document, not only this projection" do
      refute :document in WorkDisclosure.fields_at(:trace, :glass)
      assert WorkDisclosure.tier_for(:trace, :document) == nil
    end

    test "an operator gets the shape and not the steps", context do
      operator = admin_user()
      trace = upload(context.owner, context.attempt, "glass")
      viewer = WorkDisclosure.viewer(context.repository, operator)

      projection = TraceDisclosure.project(trace, context.attempt, viewer)

      assert projection.step_count == 3
      refute Map.has_key?(projection, :document)
    end
  end

  describe "consent is a gate, and it defaults to withholding" do
    test "a trace stored with no visibility is dark and invisible", context do
      trace = upload(context.owner, context.attempt, nil)

      assert trace.visibility == "dark"

      for reader <- [nil, context.stranger, context.member, context.owner] do
        viewer = WorkDisclosure.viewer(context.repository, reader)
        assert TraceDisclosure.project(trace, context.attempt, viewer) == nil
      end
    end

    test "a dark trace is absent rather than an empty shell", context do
      trace = upload(context.owner, context.attempt, "dark")
      viewer = WorkDisclosure.viewer(context.repository, context.owner)

      assert TraceDisclosure.project(trace, context.attempt, viewer) == nil
      assert TraceDisclosure.for_attempts([context.attempt], viewer) == []
    end

    test "consent at pulse discloses the shape and withholds the digest", context do
      trace = upload(context.owner, context.attempt, "pulse")
      viewer = WorkDisclosure.viewer(context.repository, context.member)

      projection = TraceDisclosure.project(trace, context.attempt, viewer)

      assert projection.tier == :pulse
      assert projection.schema_version == "ATIF-v1.7"
      assert projection.step_count == 3
      assert projection.recorded_at
      refute Map.has_key?(projection, :digest)
      refute Map.has_key?(projection, :byte_size)
    end

    test "consent at ledger adds the digest, which is the only field that travels",
         context do
      trace = upload(context.owner, context.attempt, "ledger")
      viewer = WorkDisclosure.viewer(context.repository, context.member)

      projection = TraceDisclosure.project(trace, context.attempt, viewer)

      assert projection.tier == :ledger
      assert projection.digest == trace.digest
      assert projection.byte_size == trace.byte_size
    end

    test "consent is a ceiling the viewer's own rung cannot raise", context do
      trace = upload(context.owner, context.attempt, "pulse")

      # An operator reaches `glass` on everything else about this attempt.
      viewer = WorkDisclosure.viewer(context.repository, admin_user())

      assert TraceDisclosure.effective_tier(trace, context.attempt, viewer) == :pulse
    end
  end

  describe "repository access is the other gate, and it is the stronger one" do
    test "a reader who cannot read the repository sees no trace, however wide the consent",
         context do
      trace = upload(context.owner, context.attempt, "glass")
      go_private(context.repository)

      # The activity read is where repository authority is applied, so the
      # assertion belongs at that seam rather than at the projection.
      activity = Activity.for_issue(context.issue, context.stranger)

      assert activity.traces == []
      assert trace.visibility == "glass"
    end

    test "a member of that private repository still sees the shape", context do
      _trace = upload(context.owner, context.attempt, "ledger")
      go_private(context.repository)

      activity = Activity.for_issue(context.issue, context.member)

      assert [projection] = activity.traces
      assert projection.assignment_id == context.attempt.id
      assert projection.step_count == 3
      refute Map.has_key?(projection, :document)
    end

    test "an anonymous reader of a public repository gets pulse and no digest", context do
      _trace = upload(context.owner, context.attempt, "ledger")

      activity = Activity.for_issue(context.issue, nil)

      assert [projection] = activity.traces
      assert projection.tier == :pulse
      refute Map.has_key?(projection, :digest)
    end
  end

  describe "binding a trace to an attempt is checked, not believed" do
    test "the requesting account may bind", context do
      assert {:ok, trace, :created} =
               Traces.store(context.owner, @document, assignment_id: context.attempt.id)

      assert trace.assignment_id == context.attempt.id
    end

    test "another account may not, and is refused rather than silently unbound", context do
      assert {:error, :trace_assignment_forbidden} =
               Traces.store(context.stranger, @document, assignment_id: context.attempt.id)
    end

    test "an attempt that does not exist is refused", context do
      assert {:error, :trace_assignment_forbidden} =
               Traces.store(context.owner, @document, assignment_id: Ecto.UUID.generate())
    end

    test "a malformed identifier is refused rather than raising", context do
      assert {:error, :trace_assignment_forbidden} =
               Traces.store(context.owner, @document, assignment_id: "not-a-uuid")
    end

    test "an unbound upload is still the ordinary case", context do
      assert {:ok, trace, :created} = Traces.store(context.owner, @document)
      assert is_nil(trace.assignment_id)
      assert Activity.for_issue(context.issue, context.owner).traces == []
    end
  end

  describe "a malformed document does not break the page" do
    test "a document with no steps reports zero rather than raising", context do
      {:ok, trace, :created} =
        Traces.store(context.owner, %{"schema_version" => "ATIF-v1.7"},
          assignment_id: context.attempt.id,
          visibility: "pulse"
        )

      viewer = WorkDisclosure.viewer(context.repository, context.member)
      projection = TraceDisclosure.project(trace, context.attempt, viewer)

      assert projection.step_count == 0
    end
  end

  defp go_private(repository) do
    {1, _} =
      Repo.update_all(
        Ecto.Query.from(r in OpenAgents.Repositories.Repository, where: r.id == ^repository.id),
        set: [visibility: "private"]
      )

    :ok
  end

  defp upload(user, attempt, visibility) do
    options =
      [assignment_id: attempt.id] ++
        if visibility, do: [visibility: visibility], else: []

    # A distinct document per upload, because `store/3` deduplicates on the
    # canonical bytes per account.
    document = Map.put(@document, "session_id", "s#{System.unique_integer([:positive])}")

    {:ok, trace, _} = Traces.store(user, document, options)
    trace
  end

  # The run never starts in a test. The assignment is committed by
  # `persist_assignment/7` before `start_target/7` is reached, so the row this
  # returns is the row the production path writes.
  defp admit(owner, repository, issue) do
    {:ok, conversation} = Conversations.ensure_conversation(owner)

    {:ok, box} =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_trace_#{System.unique_integer([:positive])}",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert()

    _ =
      try do
        Assignments.create(%{
          "target_kind" => "box",
          "box_id" => box.box_id,
          "conversation_id" => conversation.id,
          "repository_id" => repository.id,
          "issue_number" => issue.number,
          "branch" => "agent/issue-#{issue.number}",
          "requesting_user" => owner,
          "requesting_principal" => owner
        })
      rescue
        error -> {:error, error}
      end

    Assignment
    |> Repo.get_by!(issue_id: issue.id)
    |> Repo.preload([:artifact_link, :work_job])
  end

  # The operator identity is the one `OpenAgents.Accounts.admin?/1` admits, so
  # this needs no global state and stays safe to run concurrently.
  defp admin_user do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: 14_167_547,
        github_login: "trace-operator",
        github_avatar_url: "https://avatars.githubusercontent.com/u/14167547?v=4"
      })

    true = OpenAgents.Accounts.admin?(user)
    user
  end
end
