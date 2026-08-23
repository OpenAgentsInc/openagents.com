defmodule OpenAgents.Forge.AssignmentTest do
  use OpenAgents.DataCase, async: true

  import Ecto.Query
  import OpenAgents.AccountsFixtures

  alias OpenAgents.Forge.{Assignment, AssignmentCredential}
  alias OpenAgents.Accounts
  alias OpenAgents.Agents
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.GitReceivePack
  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Repo
  alias OpenAgents.Repositories

  test "assignment changesets require a branch and lifecycle timestamps" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset =
      Assignment.changeset(%Assignment{}, %{
        conversation_box_id: Ecto.UUID.generate(),
        repository_id: Ecto.UUID.generate(),
        issue_id: 1,
        requesting_principal: %{"type" => "agent", "id" => Ecto.UUID.generate()},
        branch: "agent/issue-1",
        deadline_at: now,
        admitted_at: now
      })

    assert changeset.valid?
    assignment = Ecto.Changeset.apply_changes(changeset)
    assert assignment.state == "admitted"
    refute Assignment.terminal?(assignment)
  end

  test "assignment changesets support a Computer target without changing Box defaults" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset =
      Assignment.changeset(%Assignment{}, %{
        target_kind: "computer",
        machine_id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        repository_id: Ecto.UUID.generate(),
        issue_id: 1,
        requesting_principal: %{"type" => "agent", "id" => Ecto.UUID.generate()},
        branch: "agent/computer-issue-1",
        deadline_at: DateTime.add(now, 60, :second),
        admitted_at: now
      })

    assert changeset.valid?
    assignment = Ecto.Changeset.apply_changes(changeset)
    assert assignment.target_kind == "computer"
    assert assignment.machine_id
    assert is_nil(assignment.conversation_box_id)
  end

  test "Computer assignments require a machine target" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset =
      Assignment.changeset(%Assignment{}, %{
        target_kind: "computer",
        conversation_id: Ecto.UUID.generate(),
        repository_id: Ecto.UUID.generate(),
        issue_id: 1,
        requesting_principal: %{"type" => "agent", "id" => Ecto.UUID.generate()},
        branch: "agent/computer-issue-1",
        deadline_at: DateTime.add(now, 60, :second),
        admitted_at: now
      })

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).machine_id
  end

  test "assignment credentials keep only a digest and metadata" do
    digest = :crypto.hash(:sha256, "oa_assignment_secret")

    changeset =
      AssignmentCredential.changeset(%AssignmentCredential{}, %{
        assignment_id: Ecto.UUID.generate(),
        token_digest: digest,
        last_four: "cret",
        repository_id: Ecto.UUID.generate(),
        branch: "agent/issue-1",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    assert changeset.valid?
    credential = Ecto.Changeset.apply_changes(changeset)
    assert credential.token_digest == digest
    refute Map.has_key?(Map.from_struct(credential), :token)
    refute Map.has_key?(Map.from_struct(credential), :plaintext)
  end

  test "invalid assignment credentials are refused" do
    assert {:error, :invalid_assignment_credential} =
             OpenAgents.Forge.Assignments.authenticate("oa_assignment_not-a-credential")
  end

  test "Box control grants require a linked human and are revocable" do
    {:ok, agent, _token} =
      Agents.register(%{
        handle: "assignment-grant-agent",
        display_name: "Assignment grant agent",
        registration_ip: "192.0.2.55"
      })

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: 9_991_055,
        github_login: "assignment-grant-user",
        github_avatar_url: "https://avatars.githubusercontent.com/u/9991055?v=4"
      })

    {:ok, link} = Agents.request_link(agent, user)
    {:ok, _link} = Agents.accept_link(user, link.id)
    refute Agents.box_control_granted?(agent)

    assert {:ok, grant} = Agents.grant_box_control(user, agent)
    assert grant.granted_by_id == user.id
    assert Agents.box_control_granted?(agent)

    assert {:ok, revoked} = Agents.revoke_box_control(user, agent)
    assert revoked.revoked_at
    refute Agents.box_control_granted?(agent)
  end

  test "receive-pack parsing accepts shallow lines and trailing newlines" do
    shallow = pkt_line("shallow " <> String.duplicate("a", 40) <> "\n")

    update =
      pkt_line(
        String.duplicate("0", 40) <>
          " " <> String.duplicate("b", 40) <> " refs/heads/agent/issue-1\n"
      )

    assert {:ok, ["refs/heads/agent/issue-1"]} =
             GitReceivePack.refs(shallow <> update <> "0000")

    assert {:error, :invalid_receive_pack} =
             GitReceivePack.refs(pkt_line("malformed\n") <> "0000")
  end

  test "assignment claim and release are visible on the issue timeline" do
    user = repository_user_fixture("assignment-timeline")

    {:ok, repository} =
      Repositories.create_repository(%{
        owner: "AssignmentTimeline",
        name: "assignment-timeline-#{System.unique_integer([:positive])}",
        visibility: "private"
      })

    {:ok, issue} = Issues.create_issue(repository, %{title: "Timeline assignment"})
    {:ok, conversation} = Conversations.ensure_conversation("assignment-timeline")

    {:ok, box} =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_assignment_timeline",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assignment =
      %Assignment{}
      |> Assignment.changeset(%{
        conversation_box_id: box.id,
        repository_id: repository.id,
        issue_id: issue.id,
        requesting_principal: %{
          "type" => "user",
          "id" => user.id,
          "actor_type" => "user",
          "actor_id" => user.id
        },
        branch: "agent/timeline",
        deadline_at: DateTime.add(now, 60, :second),
        admitted_at: now
      })
      |> Repo.insert!()

    assert {:ok, _comment} = OpenAgents.Forge.Assignments.report_claim(assignment)

    assert {:ok, _finished} =
             OpenAgents.Forge.Assignments.finish(assignment, "failed", nil, "test")

    bodies =
      Repo.all(
        from comment in Comment,
          where: comment.issue_id == ^issue.id,
          order_by: [asc: comment.created_at],
          select: comment.body
      )

    assert Enum.any?(bodies, &String.contains?(&1, "Box assignment claimed."))
    assert Enum.any?(bodies, &String.contains?(&1, "claim released."))
    assert Repo.get!(OpenAgents.Issues.Issue, issue.id).state == "open"
  end

  defp pkt_line(line) do
    line
    |> byte_size()
    |> Kernel.+(4)
    |> Integer.to_string(16)
    |> String.pad_leading(4, "0")
    |> Kernel.<>(line)
  end
end
