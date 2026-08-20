defmodule OpenAgents.IncidentsTest do
  use OpenAgents.SarahDataCase
  alias OpenAgents.Incidents
  alias OpenAgents.Incidents.Triage
  alias OpenAgents.{Accounts, Conversations, Repo}

  describe "Triage.classify/1" do
    test "maps expected, degraded, and unknown codes to tiers" do
      assert Triage.classify("cancelled") == "expected"
      assert Triage.classify("machine_offline") == "expected"
      assert Triage.classify("provider_timeout") == "degraded"
      assert Triage.classify("turn_timeout") == "degraded"
      assert Triage.classify("delegation_timeout") == "degraded"
      assert Triage.classify("delegation_refused") == "expected"
      assert Triage.classify("delegation_cancelled") == "expected"
      assert Triage.classify("delegation_failed") == "anomalous"
      assert Triage.classify("task_exit") == "degraded"
      assert Triage.classify("task_exit:RuntimeError") == "degraded"
      assert Triage.classify("transport") == "degraded"
      assert Triage.classify("transport:provider_task_exited") == "degraded"
      assert Triage.classify("provider_task_exited") == "degraded"
      # Unrecognized families stay anomalous — the whole point.
      assert Triage.classify("something_we_never_saw") == "anomalous"
      assert Triage.classify(nil) == "anomalous"
    end

    test "classifies on the family head of a family:detail code" do
      assert Triage.classify("provider_timeout:read") == "degraded"
      assert Triage.classify("cancelled:by_user") == "expected"
    end
  end

  describe "record/1" do
    test "classifies severity from the code and stores an owner-scoped incident" do
      scope = owner_scope("incident-record")

      assert {:ok, incident} =
               Incidents.record(%{
                 conversation_id: scope.conversation.id,
                 owner_user_id: scope.user.id,
                 owner_visitor_id: scope.owner.id,
                 surface: "text",
                 origin: "turn_server",
                 correlation_ref: "turn-1",
                 code: "transport:provider_task_exited",
                 summary: "Text turn failed"
               })

      assert incident.severity == "degraded"
      assert incident.status == "open"
      assert incident.owner_user_id == scope.user.id
    end

    test "defaults a missing code to task_exit, never unknown" do
      scope = owner_scope("incident-default-code")

      assert {:ok, incident} =
               Incidents.record(%{
                 conversation_id: scope.conversation.id,
                 owner_user_id: scope.user.id,
                 owner_visitor_id: scope.owner.id,
                 surface: "text",
                 origin: "turn_server"
               })

      assert incident.code == "task_exit"
      assert incident.severity == "degraded"
      refute incident.code == "unknown"
    end

    test "scrubs credential material and bounds oversize context" do
      scope = owner_scope("incident-scrub")
      # A value that reads as a card number must never be stored verbatim.
      secret = "4111 1111 1111 1111"

      assert {:ok, incident} =
               Incidents.record(%{
                 conversation_id: scope.conversation.id,
                 owner_user_id: scope.user.id,
                 owner_visitor_id: scope.owner.id,
                 surface: "text",
                 origin: "turn_server",
                 code: "transport",
                 context: %{"note" => secret, "tool" => "computer_agent"}
               })

      refute incident.context["note"] == secret
      assert incident.context["tool"] == "computer_agent"
    end

    test "a long context value is truncated so nothing unbounded is stored" do
      scope = owner_scope("incident-bound")
      huge = String.duplicate("x", 20_000)

      assert {:ok, incident} =
               Incidents.record(%{
                 conversation_id: scope.conversation.id,
                 owner_user_id: scope.user.id,
                 owner_visitor_id: scope.owner.id,
                 surface: "text",
                 origin: "turn_server",
                 code: "transport",
                 context: %{"blob" => huge}
               })

      assert String.length(incident.context["blob"]) <= 500
    end

    test "a context that overflows even after per-value bounding gets a marker" do
      scope = owner_scope("incident-overflow")
      # Many keys, each bounded to 500 chars, sum past the 8 KB cap.
      context = for n <- 1..40, into: %{}, do: {"k#{n}", String.duplicate("y", 500)}

      assert {:ok, incident} =
               Incidents.record(%{
                 conversation_id: scope.conversation.id,
                 owner_user_id: scope.user.id,
                 owner_visitor_id: scope.owner.id,
                 surface: "text",
                 origin: "turn_server",
                 code: "transport",
                 context: context
               })

      assert incident.context["truncated"] == true
    end
  end

  describe "list_recent/2 and recurrence_count/2" do
    test "scopes to the owner and this conversation, newest first" do
      scope = owner_scope("incident-list")
      other = owner_scope("incident-list-other")

      for code <- ["a", "b", "c"] do
        {:ok, _} = record(scope, code)
      end

      {:ok, _foreign} = record(other, "z")

      recent = Incidents.list_recent(scope.user.id, conversation_id: scope.conversation.id)
      assert length(recent) == 3
      # Never another owner's incident.
      refute Enum.any?(recent, &(&1.code == "z"))
    end

    test "counts recurrences of a code for an owner" do
      scope = owner_scope("incident-recur")
      {:ok, _} = record(scope, "transport")
      {:ok, _} = record(scope, "transport")
      {:ok, _} = record(scope, "other")

      assert Incidents.recurrence_count(scope.user.id, "transport") == 2
      assert Incidents.recurrence_count(scope.user.id, "other") == 1
    end
  end

  describe "report/1" do
    test "records and, with the fixer disabled, never spawns a job" do
      scope = owner_scope("incident-report")

      assert {:ok, incident} =
               Incidents.report(%{
                 conversation_id: scope.conversation.id,
                 owner_user_id: scope.user.id,
                 owner_visitor_id: scope.owner.id,
                 surface: "text",
                 origin: "turn_server",
                 code: "transport:provider_task_exited"
               })

      assert incident.severity == "degraded"
      # Fixer is off by default: the incident is recorded but not being fixed.
      assert is_nil(incident.fixer_job_id)
    end
  end

  defp record(scope, code) do
    Incidents.record(%{
      conversation_id: scope.conversation.id,
      owner_user_id: scope.user.id,
      owner_visitor_id: scope.owner.id,
      surface: "text",
      origin: "turn_server",
      code: code
    })
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
