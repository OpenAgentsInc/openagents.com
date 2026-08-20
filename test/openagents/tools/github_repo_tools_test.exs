defmodule OpenAgents.Tools.GitHubRepoToolsTest do
  use OpenAgents.DataCase

  alias OpenAgents.Conversations.Message
  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner}
  alias OpenAgents.{Accounts, Conversations, Repo}

  @tools [OpenAgents.Tools.GitHubRepoList, OpenAgents.Tools.GitHubRepoRead]

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.get_env(:openagents, :github_api)

    Application.put_env(:openagents, :github_api,
      base_url: "https://github-api.internal",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:openagents, :github_api, original) end)

    assert {:ok, snapshot} = Registry.build(@tools)
    %{snapshot: snapshot}
  end

  test "a signed-in user's stored token lists their repositories without leaking", %{
    snapshot: snapshot
  } do
    scope = github_scope("repo-lister", "gho_stored-for-listing")

    Req.Test.expect(__MODULE__, fn conn ->
      assert ["Bearer gho_stored-for-listing"] =
               Plug.Conn.get_req_header(conn, "authorization")

      Req.Test.json(conn, [
        %{
          "full_name" => "repo-lister/sarah",
          "description" => "Assistant",
          "private" => false,
          "default_branch" => "main",
          "language" => "Elixir",
          "pushed_at" => "2026-08-16T12:00:00Z"
        }
      ])
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("github_repo_list", %{"first" => 10}),
               context(scope)
             )

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["github_login"] == "repo-lister"
    assert [%{"full_name" => "repo-lister/sarah"}] = outcome["result"]["repositories"]
    refute inspect(outcome) =~ "gho_stored-for-listing"
  end

  test "repository files are read with the stored token", %{snapshot: snapshot} do
    scope = github_scope("repo-reader", "gho_stored-for-reading")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/repo-reader/demo/contents/mix.exs"

      Req.Test.json(conn, %{
        "type" => "file",
        "path" => "mix.exs",
        "size" => 20,
        "encoding" => "base64",
        "content" => Base.encode64("defmodule Demo do")
      })
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("github_repo_read", %{
                 "repository" => "repo-reader/demo",
                 "path" => "mix.exs",
                 "ref" => ""
               }),
               context(scope)
             )

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["type"] == "file"
    assert outcome["result"]["content"] == "defmodule Demo do"
    refute inspect(outcome) =~ "gho_stored-for-reading"
  end

  test "visitors without a linked GitHub token are refused safely", %{snapshot: snapshot} do
    assert {:ok, conversation} = Conversations.ensure_conversation("anonymous-browser")
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)
    message = user_message(conversation)

    execution_context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{conversation.id}",
      authorities: MapSet.new(["github.read"]),
      conversation_id: conversation.id,
      current_user_message_id: message.id,
      owner_visitor_id: owner.id
    }

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("github_repo_list", %{"first" => 10}),
               execution_context
             )

    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "github_not_connected"
  end

  test "a rejected provider token fails without exposing it", %{snapshot: snapshot} do
    scope = github_scope("repo-revoked", "gho_revoked-token")

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
    end)

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("github_repo_list", %{"first" => 10}),
               context(scope)
             )

    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "github_token_rejected"
    refute inspect(outcome) =~ "gho_revoked-token"
  end

  defp call(name, arguments) do
    %{
      call_id: "call-#{System.unique_integer([:positive])}",
      name: name,
      version: 1,
      raw_arguments: Jason.encode!(arguments)
    }
  end

  defp github_scope(login, token) do
    assert {:ok, user} =
             Accounts.upsert_github_user(%{
               github_id: System.unique_integer([:positive]),
               github_login: login,
               github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
             })

    assert {:ok, user} = Accounts.store_github_token(user, token)
    assert {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)
    %{user: user, owner: owner, conversation: conversation}
  end

  defp user_message(conversation) do
    Repo.insert!(%Message{
      conversation_id: conversation.id,
      role: "user",
      status: "complete",
      content: "Show me my repos"
    })
  end

  defp context(scope) do
    message = user_message(scope.conversation)

    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{scope.conversation.id}",
      authorities: MapSet.new(["github.read"]),
      conversation_id: scope.conversation.id,
      current_user_message_id: message.id,
      owner_visitor_id: scope.owner.id
    }
  end
end
