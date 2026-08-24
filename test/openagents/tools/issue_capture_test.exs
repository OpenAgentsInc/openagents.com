defmodule OpenAgents.Tools.IssueCaptureTest do
  @moduledoc """
  The `capture_issue` tool, driven through `OpenAgents.Tools.Runner` (#77).

  The domain rules are proven in `OpenAgents.Issues.CaptureTest`. What this
  file proves is the part only the tool has: that the ask-every-time gate is
  real, that a caller's own membership is what files the issue, and that the
  typed refusals a person reads say which authority is missing.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.{Accounts, Conversations, Issues, Repositories}
  alias OpenAgents.Tools.{AdmittedCatalog, ConversationExecutionContext, Registry, Runner}

  @modules [OpenAgents.Tools.IssueCapture, OpenAgents.Tools.ModuleDiscover]

  setup do
    {:ok, snapshot} = Registry.build(@modules)
    scope = signed_in_scope("issue-capture")
    repository = repository_with_member_fixture(scope.user, %{}, "maintainer")

    %{snapshot: snapshot, scope: scope, repository: repository}
  end

  describe "filing for an authorized caller" do
    test "creates the issue and returns its number and URL", context do
      assert {:ok, outcome} =
               capture(context, %{repository: path(context), problem: "Add CSV export."})

      assert outcome["status"] == "succeeded"

      result = outcome["result"]
      assert result["schema"] == "openagents.captured_issue.v1"
      assert result["outcome"] == "created"
      assert result["title"] == "Add CSV export"
      assert result["state"] == "open"
      assert result["number"] > 0
      assert result["repository"] == path(context)
      assert result["url"] =~ "/#{path(context)}/issues/#{result["number"]}"

      issue = Issues.get_issue_by_number!(context.repository, result["number"])
      assert issue.author_user_id == context.scope.user.id
    end

    # TOOL-004: an external effect must name what it affected.
    test "the outcome names the issue it created", context do
      assert {:ok, outcome} =
               capture(context, %{repository: path(context), problem: "Add CSV export."})

      assert [reference] = outcome["target_receipt_refs"]
      assert reference =~ "forge-issue:"
    end

    test "a repeat returns the first issue rather than filing a second", context do
      assert {:ok, first} =
               capture(context, %{repository: path(context), problem: "Add CSV export."})

      assert {:ok, second} =
               capture(context, %{repository: path(context), problem: "Add CSV export."})

      assert first["result"]["outcome"] == "created"
      assert second["result"]["outcome"] == "existing"
      assert second["result"]["number"] == first["result"]["number"]
      assert length(Issues.list_issues(context.repository, state: "all")) == 1
    end
  end

  describe "refusing a caller without write access" do
    test "names the missing role instead of failing vaguely", context do
      stranger = signed_in_scope("issue-capture-stranger")
      other = repository_with_member_fixture(stranger.user, %{}, "owner")
      {:ok, _membership} = Repositories.add_member(other, context.scope.user, "viewer")

      assert {:ok, outcome} =
               capture(context, %{
                 repository: other.owner <> "/" <> other.name,
                 problem: "Add CSV export."
               })

      assert outcome["status"] == "refused"
      assert outcome["error"]["code"] == "repository_write_access_required"
      assert outcome["error"]["message"] =~ "write access"
      assert outcome["error"]["message"] =~ "owner, maintainer, or contributor"
      refute outcome["error"]["message"] == "The tool call failed validation or execution."

      assert Issues.list_issues(other, state: "all") == []
    end

    # A refusal must not double as an existence oracle for a private repository.
    test "a repository the caller cannot see is absent, not merely unwritable", context do
      stranger = signed_in_scope("issue-capture-private")
      private = repository_with_member_fixture(stranger.user, %{visibility: "private"}, "owner")

      assert {:ok, outcome} =
               capture(context, %{
                 repository: private.owner <> "/" <> private.name,
                 problem: "Add CSV export."
               })

      # `repository_not_found` classifies as `failed` rather than `refused`,
      # the same as it does for the read-only repository tools: the caller is
      # not being told they lack authority, they are being told there is
      # nothing there. Keeping the two apart is the point of the test.
      refute outcome["status"] == "succeeded"
      assert outcome["error"]["code"] == "repository_not_found"
    end

    test "a conversation that resolves to no account files nothing", %{snapshot: snapshot} do
      assert {:ok, outcome} =
               Runner.run(
                 snapshot,
                 call(%{repository: "OpenAgentsInc/openagents.com", problem: "Add CSV export."}),
                 unbound_context(snapshot)
               )

      refute outcome["status"] == "succeeded"
      assert outcome["error"]["code"] == "repository_authentication_required"
    end
  end

  describe "the ask-every-time gate" do
    # The whole basis on which a writing tool is admitted to the shipped
    # catalog at all (TOOL-006). If this stops holding, `capture_issue` becomes
    # a tool the model can file public issues with unasked.
    test "without a current receipt the tool refuses", context do
      assert {:ok, outcome} =
               Runner.run(
                 context.snapshot,
                 call(%{repository: path(context), problem: "Add CSV export."}),
                 consentless_context(context)
               )

      assert outcome["status"] == "refused"
      assert outcome["error"]["code"] == "module_approval_required"
      assert Issues.list_issues(context.repository, state: "all") == []
    end

    test "without a current receipt the tool is not even offered", context do
      offered = offered(context.snapshot, consentless_context(context))

      refute "capture_issue" in offered
      assert "module_discover" in offered
    end

    test "with a current receipt it is offered", context do
      assert "capture_issue" in offered(context.snapshot, consenting_context(context))
    end

    # Consent is scoped to one conversation. A receipt minted elsewhere is not
    # a standing grant this conversation can spend.
    test "a receipt for another conversation does not carry over", context do
      elsewhere = %{
        consentless_context(context)
        | approval_receipts: [receipt("conversation:#{Ecto.UUID.generate()}")]
      }

      assert {:ok, outcome} =
               Runner.run(
                 context.snapshot,
                 call(%{repository: path(context), problem: "Add CSV export."}),
                 elsewhere
               )

      assert outcome["status"] == "refused"
      assert outcome["error"]["code"] == "module_approval_required"
    end
  end

  describe "the declaration" do
    test "says it writes, and says when not to call it", %{snapshot: snapshot} do
      tool = Map.fetch!(snapshot.tools, "capture_issue")

      assert tool.side_effect == :external_effect
      assert tool.required_authority == "repository.write"
      assert tool.reach == [:signed_in_owner]
      assert tool.module_metadata["approval_class"] == "external_confirmation"
      assert tool.module_metadata["facets"]["approval_enforcement"] == "host_receipt"

      # Re-admission criterion 5: a description that only names a capability
      # makes the model try the tool and read the refusal.
      assert tool.description =~ "Do not call"
      assert tool.description =~ "Do not guess the repository"

      # The authority a conversation caller actually holds.
      assert MapSet.member?(ConversationExecutionContext.authorities(), tool.required_authority)
    end
  end

  defp capture(context, arguments) do
    Runner.run(context.snapshot, call(arguments), consenting_context(context))
  end

  defp call(arguments) do
    %{
      call_id: "call-#{System.unique_integer([:positive])}",
      name: "capture_issue",
      version: 1,
      raw_arguments: JSON.encode!(arguments)
    }
  end

  defp path(%{repository: repository}), do: repository.owner <> "/" <> repository.name

  defp offered(snapshot, context) do
    snapshot
    |> AdmittedCatalog.provider_definitions(context, "file this request as an issue", top_k: 64)
    |> Enum.map(& &1.name)
  end

  defp consentless_context(%{scope: scope, snapshot: snapshot}) do
    ConversationExecutionContext.build(%{
      surface: "text",
      conversation_id: scope.conversation.id,
      owner_visitor_id: scope.owner.id,
      owner_user_id: scope.owner.user_id,
      module_registry_snapshot: snapshot
    })
  end

  defp consenting_context(context) do
    consentless = consentless_context(context)
    %{consentless | approval_receipts: [receipt(consentless.scope_ref)]}
  end

  # What a consent surface mints when the person confirms this one filing:
  # bound to the module, the version, and this conversation, and explicit.
  defp receipt(scope_ref) do
    %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "external_confirmation",
      "module_id" => "sarah.tool.issue_capture.v1",
      "version" => 1,
      "scope_ref" => scope_ref,
      "explicit" => true,
      "actor_type" => "person",
      "receipt_ref" => "issue-capture-consent:#{System.unique_integer([:positive])}"
    }
  end

  defp unbound_context(snapshot) do
    %OpenAgents.Tools.ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:unbound",
      authorities: ConversationExecutionContext.authorities(),
      approval_receipts: [receipt("conversation:unbound")],
      surface: "text",
      module_registry_snapshot: snapshot
    }
  end

  defp signed_in_scope(login) do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "#{login}-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    %{user: user, owner: owner, conversation: conversation}
  end
end
