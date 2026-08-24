defmodule OpenAgents.Tools.ReachTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Accounts
  alias OpenAgents.Conversations
  alias OpenAgents.Machines

  alias OpenAgents.Tools.{
    AdmittedCatalog,
    ConversationExecutionContext,
    OwnerContext,
    Reach,
    Registry,
    Runner
  }

  @delegation "delegate this coding task to my computer and deploy an agent for it"

  # The test tool list omits the tools that need external services, and two of
  # them — `scv_deploy` above all — are exactly the ones whose reach this file
  # exists to prove. Build the shipped catalog instead.
  @production_only [
    OpenAgents.Tools.BoxExec,
    OpenAgents.Tools.BoxList,
    OpenAgents.Tools.BoxNew,
    OpenAgents.Tools.BoxStop,
    OpenAgents.Tools.ScvDeploy
  ]

  setup do
    modules = Enum.uniq(Application.fetch_env!(:openagents, :tools) ++ @production_only)
    {:ok, snapshot} = Registry.build(modules)
    %{snapshot: snapshot}
  end

  describe "what each tool needs from its caller" do
    test "the catalog records the requirement, so adding a tool forces the decision", %{
      snapshot: snapshot
    } do
      declared =
        for {name, tool} <- snapshot.tools, tool.reach != [], into: %{}, do: {name, tool.reach}

      # `computer_list` deliberately needs no paired Computer: listing zero of
      # them is how the model learns to tell the person to pair one. Repository
      # *read* tools declare nothing because their gate is per-repository
      # membership, which depends on an argument the catalog has not seen yet.
      # `capture_issue` does declare an owner: it files under the person's own
      # membership, so no owner means no possible success, whatever repository
      # the argument later names.
      assert declared == %{
               "capture_issue" => [:signed_in_owner],
               "computer_agent" => [:signed_in_owner, :paired_computer],
               "computer_devin" => [:signed_in_owner, :paired_computer],
               "computer_list" => [:signed_in_owner],
               "computer_probe" => [:signed_in_owner, :paired_computer],
               "computer_run" => [:signed_in_owner, :paired_computer],
               "deep_work" => [:signed_in_owner],
               "incident_lookup" => [:signed_in_owner],
               "scv_deploy" => [:signed_in_owner, :operator]
             }
    end
  end

  describe "narrowing the offered set" do
    test "a caller with no resolvable owner is offered no tool that needs one", %{
      snapshot: snapshot
    } do
      names = offered(snapshot, unbound_context(snapshot))

      for name <- owner_requiring(snapshot) do
        refute name in names,
               "#{name} needs an owner but was offered to a caller who has none"
      end

      assert "module_discover" in names
    end

    test "a signed-in caller without a Computer keeps computer_list and loses the rest", %{
      snapshot: snapshot
    } do
      scope = signed_in_scope("reach-no-computer")
      names = offered(snapshot, context(scope, snapshot))

      # `computer_list` survives: it is the tool that tells the person they have
      # nothing paired yet, so removing it would hide the way out.
      assert "computer_list" in names
      assert "incident_lookup" in names
      assert "deep_work" in names
      refute "computer_agent" in names
      refute "computer_devin" in names
      refute "computer_probe" in names
      refute "computer_run" in names
    end

    test "pairing a Computer puts the delegation chain back", %{snapshot: snapshot} do
      scope = signed_in_scope("reach-paired-computer")
      _machine = paired_machine(scope.user)

      names = offered(snapshot, context(scope, snapshot))

      assert Machines.active_machine?(scope.user.id)
      assert "computer_agent" in names
      assert "computer_devin" in names
      assert "computer_list" in names
    end

    test "scv_deploy reaches an operator and nobody else", %{snapshot: snapshot} do
      scope = signed_in_scope("reach-not-operator")
      refute "scv_deploy" in offered(snapshot, context(scope, snapshot))

      operator = signed_in_scope("reach-operator")
      grant_operator(operator.user)
      assert Accounts.admin?(Repo.reload!(operator.user))

      assert "scv_deploy" in offered(snapshot, context(operator, snapshot))
    end
  end

  describe "the identifier boundary" do
    test "an account id is refused as a visitor id, and stays refused" do
      # Widening this to accept either kind would make the two identifier
      # spaces interchangeable, and the next mismatch silent. The account has a
      # visitor; resolve it, never substitute for it.
      scope = signed_in_scope("reach-identifier-boundary")

      assert scope.owner.id != scope.user.id
      assert scope.owner.user_id == scope.user.id

      assert {:error, :owner_not_signed_in} =
               OwnerContext.resolve(%OpenAgents.Tools.ExecutionContext{
                 scope: "browser_conversation",
                 scope_ref: "conversation:#{scope.conversation.id}",
                 authorities: MapSet.new(),
                 owner_visitor_id: scope.user.id
               })

      assert Reach.caller(%OpenAgents.Tools.ExecutionContext{
               scope: "browser_conversation",
               scope_ref: "conversation:#{scope.conversation.id}",
               authorities: MapSet.new(),
               owner_visitor_id: scope.user.id
             }) == Reach.unbound()
    end
  end

  describe "a refusal that does happen" do
    test "names the tool's requirement and the caller's gap", %{snapshot: snapshot} do
      # Reaching the model with `The tool call failed validation or execution.`
      # left the model to guess, and it guessed that the person was signed out.
      # The typed reason is in the payload; it belongs in the message too.
      assert {:ok, outcome} =
               Runner.run(
                 snapshot,
                 %{
                   call_id: "call-#{System.unique_integer([:positive])}",
                   name: "incident_lookup",
                   version: 1,
                   raw_arguments: ~s({"scope":"owner"})
                 },
                 unbound_context(snapshot)
               )

      assert outcome["status"] == "refused"
      assert outcome["error"]["code"] == "owner_not_signed_in"
      assert outcome["error"]["message"] =~ "signed-in account"
      refute outcome["error"]["message"] == "The tool call failed validation or execution."
    end
  end

  describe "unmet/2" do
    test "names the gap rather than only reporting a boolean", %{snapshot: snapshot} do
      tool = Map.fetch!(snapshot.tools, "computer_devin")

      assert Reach.unmet(tool, Reach.unbound()) == [:signed_in_owner, :paired_computer]
      assert Reach.reachable?(Map.fetch!(snapshot.tools, "module_discover"), Reach.unbound())
    end
  end

  # `top_k` covers the whole catalog on purpose: these tests measure who can
  # reach a tool, never how relevance ranking orders it.
  defp offered(snapshot, context) do
    snapshot
    |> AdmittedCatalog.provider_definitions(context, @delegation, top_k: 64)
    |> Enum.map(& &1.name)
  end

  defp owner_requiring(snapshot) do
    for {name, tool} <- snapshot.tools, :signed_in_owner in tool.reach, do: name
  end

  defp unbound_context(snapshot) do
    %OpenAgents.Tools.ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:unbound",
      authorities: ConversationExecutionContext.authorities(),
      surface: "text",
      module_registry_snapshot: snapshot
    }
  end

  defp context(scope, snapshot) do
    ConversationExecutionContext.build(%{
      surface: "text",
      conversation_id: scope.conversation.id,
      owner_visitor_id: scope.owner.id,
      owner_user_id: scope.owner.user_id,
      module_registry_snapshot: snapshot
    })
  end

  defp signed_in_scope(login) do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    # The owner the catalog resolves must be the same account the tools resolve.
    assert {:ok, resolved} =
             OwnerContext.resolve(%OpenAgents.Tools.ExecutionContext{
               scope: "browser_conversation",
               scope_ref: "conversation:#{conversation.id}",
               authorities: MapSet.new(),
               owner_visitor_id: owner.id
             })

    assert resolved.id == user.id

    %{user: user, owner: owner, conversation: conversation}
  end

  defp paired_machine(user) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "reach-machine-#{System.unique_integer([:positive])}",
        "tier" => "probe",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/Users/test/work"]
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end

  defp grant_operator(%{github_id: github_id}) do
    :global.trans({{:openagents, :admin_github_ids}, self()}, fn ->
      ids = Application.get_env(:openagents, :admin_github_ids, [])
      Application.put_env(:openagents, :admin_github_ids, [github_id | ids])
    end)

    on_exit(fn ->
      :global.trans({{:openagents, :admin_github_ids}, self()}, fn ->
        ids = Application.get_env(:openagents, :admin_github_ids, [])
        Application.put_env(:openagents, :admin_github_ids, List.delete(ids, github_id))
      end)
    end)

    :ok
  end
end
