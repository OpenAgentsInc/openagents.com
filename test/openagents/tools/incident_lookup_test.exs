defmodule OpenAgents.Tools.IncidentLookupTest do
  use OpenAgents.SarahDataCase

  alias OpenAgents.Incidents
  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner}
  alias OpenAgents.{Accounts, Conversations, Repo}

  setup do
    assert {:ok, snapshot} = Registry.build([OpenAgents.Tools.IncidentLookup])
    %{snapshot: snapshot}
  end

  test "returns the owner's own incidents for this conversation", %{snapshot: snapshot} do
    scope = owner_scope("incident-tool")

    {:ok, _} =
      Incidents.record(%{
        conversation_id: scope.conversation.id,
        owner_user_id: scope.user.id,
        owner_visitor_id: scope.owner.id,
        surface: "text",
        origin: "turn_server",
        correlation_ref: "turn-x",
        code: "transport:provider_task_exited",
        summary: "Text turn failed"
      })

    assert {:ok, outcome} =
             Runner.run(snapshot, call("incident_lookup", %{}), context(scope))

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["status"] == "matches"
    assert outcome["result"]["primary"] == "incident"
    assert outcome["result"]["jobs"] == []
    assert [listed] = outcome["result"]["incidents"]
    assert listed["code"] == "transport:provider_task_exited"
    assert listed["severity"] == "degraded"
    assert listed["recurrence_count"] >= 1
  end

  test "never returns another owner's incidents", %{snapshot: snapshot} do
    scope = owner_scope("incident-tool-scoped")
    other = owner_scope("incident-tool-foreign")

    {:ok, _} =
      Incidents.record(%{
        conversation_id: other.conversation.id,
        owner_user_id: other.user.id,
        owner_visitor_id: other.owner.id,
        surface: "text",
        origin: "turn_server",
        code: "leak_me"
      })

    assert {:ok, outcome} =
             Runner.run(snapshot, call("incident_lookup", %{"scope" => "owner"}), context(scope))

    assert outcome["result"]["status"] == "none"
    assert outcome["result"]["primary"] == "none"
    assert outcome["result"]["incidents"] == []
    assert outcome["result"]["jobs"] == []
  end

  test "a newer job report is primary over a stale incident", %{snapshot: snapshot} do
    scope = owner_scope("incident-tool-stale")

    {:ok, _} =
      Incidents.record(%{
        conversation_id: scope.conversation.id,
        owner_user_id: scope.user.id,
        owner_visitor_id: scope.owner.id,
        surface: "text",
        origin: "turn_server",
        code: "unknown",
        summary: "Text turn failed: unknown"
      })

    {:ok, job} =
      OpenAgents.Work.create_job(%{
        conversation_id: scope.conversation.id,
        owner_visitor_id: scope.owner.id,
        surface: "text",
        kind: "delegation",
        goal: "Delegate to claude: input-bar refactor"
      })

    {:ok, running} = OpenAgents.Work.mark_job_running(job, %{})

    {:ok, _} =
      OpenAgents.Work.append_report_delta(
        running,
        "Delegation to claude on devin-test — timed out.\n\nTerminal: git status"
      )

    {:ok, finished} =
      OpenAgents.Work.finish_job(running.id, "failed", error_code: "delegation_timeout")

    assert {:ok, outcome} =
             Runner.run(snapshot, call("incident_lookup", %{}), context(scope))

    assert outcome["result"]["status"] == "matches"
    assert outcome["result"]["primary"] == "job"
    assert outcome["result"]["guidance"] =~ "jobs[]"
    assert [listed_job] = outcome["result"]["jobs"]
    assert listed_job["id"] == finished.id
    assert listed_job["kind"] == "delegation"
    assert listed_job["report_excerpt"] =~ "timed out"
    assert listed_job["error_code"] == "delegation_timeout"
  end

  test "correlation_ref filters incidents and jobs to that id", %{snapshot: snapshot} do
    scope = owner_scope("incident-tool-ref")

    {:ok, kept} =
      Incidents.record(%{
        conversation_id: scope.conversation.id,
        owner_user_id: scope.user.id,
        owner_visitor_id: scope.owner.id,
        surface: "text",
        origin: "turn_server",
        correlation_ref: "turn-keep",
        code: "turn_timeout"
      })

    {:ok, _} =
      Incidents.record(%{
        conversation_id: scope.conversation.id,
        owner_user_id: scope.user.id,
        owner_visitor_id: scope.owner.id,
        surface: "text",
        origin: "turn_server",
        correlation_ref: "turn-drop",
        code: "cancelled"
      })

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("incident_lookup", %{"correlation_ref" => "turn-keep"}),
               context(scope)
             )

    assert [listed] = outcome["result"]["incidents"]
    assert listed["id"] == kept.id
    assert listed["code"] == "turn_timeout"
  end

  defp call(name, arguments) do
    %{
      call_id: "call_#{System.unique_integer([:positive])}",
      name: name,
      version: 1,
      raw_arguments: Jason.encode!(arguments)
    }
  end

  defp context(scope) do
    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{scope.conversation.id}",
      authorities: MapSet.new(["conversation.read"]),
      conversation_id: scope.conversation.id,
      owner_visitor_id: scope.owner.id
    }
  end

  defp owner_scope(login) do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)
    %{user: user, owner: owner, conversation: conversation}
  end
end
