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
    end
  end

  setup tags do
    OpenAgents.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def github_user(key) when is_binary(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()
    login_suffix = digest |> Base.encode16(case: :lower) |> binary_part(0, 12)

    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: "test-#{login_suffix}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  def log_in_github_user(conn, key) when is_binary(key) do
    user = github_user(key)
    Plug.Test.init_test_session(conn, %{"user_id" => user.id})
  end

  def put_forge_api_token(conn, key) when is_binary(key) do
    user = github_user("api-token-" <> key)

    {:ok, _credential, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "test forge client",
        scopes: ["forge:write"],
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

  def grant_operator(%OpenAgents.Accounts.User{github_id: github_id}) do
    original = Application.get_env(:openagents, :admin_github_ids, [])
    Application.put_env(:openagents, :admin_github_ids, [github_id | original])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:openagents, :admin_github_ids, original)
    end)

    :ok
  end

  def revoke_operator do
    Application.put_env(:openagents, :admin_github_ids, [])
    :ok
  end
end
