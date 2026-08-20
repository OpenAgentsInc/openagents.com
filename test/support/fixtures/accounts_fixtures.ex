defmodule OpenAgents.AccountsFixtures do
  @moduledoc "Test helpers for repository-assignable accounts."

  def repository_user_fixture(login) when is_binary(login) do
    github_id = System.unique_integer([:positive, :monotonic])

    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    {:ok, _membership} = OpenAgents.Repositories.ensure_initial_membership(user)
    user
  end
end
