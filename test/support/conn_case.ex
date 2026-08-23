defmodule OpenAgentsWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use OpenAgentsWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint OpenAgentsWeb.Endpoint

      use OpenAgentsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import OpenAgentsWeb.ConnCase
      import OpenAgents.AccountsFixtures
    end
  end

  setup tags do
    OpenAgents.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def github_user(key) when is_binary(key) do
    digest = :crypto.hash(:sha256, key)
    login_suffix = digest |> Base.encode16(case: :lower) |> binary_part(0, 12)

    github_user(key, "test-#{login_suffix}")
  end

  def github_user(key, login) when is_binary(key) and is_binary(login) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()

    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  def log_in_github_user(conn, key) when is_binary(key) do
    user = github_user(key)
    Plug.Test.init_test_session(conn, %{"user_id" => user.id})
  end

  def log_in_repository_user(conn, key, repository) when is_binary(key) do
    user = github_user(key)
    {:ok, _membership} = OpenAgents.Repositories.add_member(repository, user, "owner")
    Plug.Test.init_test_session(conn, %{"user_id" => user.id})
  end

  @doc """
  Logs in an account that has already written to the agent.

  Her surfaces are grandfathered rather than launched, so an account that has
  never sent a message does not see them. A test about the sidebar's shared
  destinations wants an account that does.
  """
  def log_in_chatting_user(conn, key) when is_binary(key) do
    user = github_user(key)
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
    {:ok, _records} = OpenAgents.Conversations.create_turn(conversation, "Hello.")

    Plug.Test.init_test_session(conn, %{"user_id" => user.id})
  end

  def put_forge_api_token(conn, key) when is_binary(key) do
    user = github_user("api-token-" <> key)

    put_forge_api_token_for_user(conn, user)
  end

  def put_forge_api_token(conn, key, %OpenAgents.Repositories.Repository{} = repository)
      when is_binary(key) do
    user = github_user("api-token-" <> key)
    {:ok, _membership} = OpenAgents.Repositories.add_member(repository, user, "owner")
    put_forge_api_token_for_user(conn, user)
  end

  def put_forge_api_token(conn, key, login)
      when is_binary(key) and is_binary(login) do
    user = github_user("api-token-" <> key, login)

    put_forge_api_token_for_user(conn, user)
  end

  def put_forge_api_token(conn, key, login, %OpenAgents.Repositories.Repository{} = repository)
      when is_binary(key) and is_binary(login) do
    user = github_user("api-token-" <> key, login)
    {:ok, _membership} = OpenAgents.Repositories.add_member(repository, user, "owner")
    put_forge_api_token_for_user(conn, user)
  end

  defp put_forge_api_token_for_user(conn, user) do
    put_api_token_for_user(conn, user, ["forge:write"])
  end

  @doc """
  Authenticate an existing account for the deployment control plane.

  Deployment authority is its own scope, so a test cannot borrow `forge:write`
  to reach a deployment route.
  """
  def put_deployments_api_token(conn, %OpenAgents.Accounts.User{} = user) do
    put_api_token_for_user(conn, user, ["deployments:write"])
  end

  def put_chat_api_token(conn, key) when is_binary(key) do
    user = github_user("api-token-" <> key)
    put_api_token_for_user(conn, user, ["chat:account"])
  end

  defp put_api_token_for_user(conn, user, scopes) do
    {:ok, _credential, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "test API client",
        scopes: scopes,
        lifetime_days: 1
      })

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> plaintext)
  end

  @doc """
  Logs in an account and grants it operator access for the duration of the test.
  """
  def log_in_admin_user(conn, key) when is_binary(key) do
    user = github_user(key)
    grant_operator(user)
    Plug.Test.init_test_session(conn, %{"user_id" => user.id})
  end

  # The admin list is one application-wide value shared by every concurrently
  # running test, so each grant adds only its own id and its cleanup removes
  # only that id — restoring a snapshot would erase whatever another test
  # granted in between. The read-modify-write is serialized for the same
  # reason.
  def grant_operator(%OpenAgents.Accounts.User{github_id: github_id}) do
    update_admin_github_ids(&[github_id | &1])

    ExUnit.Callbacks.on_exit(fn ->
      update_admin_github_ids(&List.delete(&1, github_id))
    end)

    :ok
  end

  def revoke_operator do
    update_admin_github_ids(fn _ids -> [] end)
    :ok
  end

  defp update_admin_github_ids(fun) do
    :global.trans({{:openagents, :admin_github_ids}, self()}, fn ->
      ids = Application.get_env(:openagents, :admin_github_ids, [])
      Application.put_env(:openagents, :admin_github_ids, fun.(ids))
    end)

    :ok
  end
end
