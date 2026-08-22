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

    user
  end

  def repository_fixture(attrs \\ %{}) do
    suffix = System.unique_integer([:positive, :monotonic])

    defaults = %{
      owner: "TestOrg#{suffix}",
      name: "test-repository-#{suffix}",
      visibility: "public",
      default_branch: "main"
    }

    {:ok, repository} =
      defaults
      |> Map.merge(Map.new(attrs))
      |> OpenAgents.Repositories.create_repository()

    repository
  end

  def repository_with_member_fixture(user, attrs \\ %{}, role \\ "owner") do
    repository = repository_fixture(attrs)
    {:ok, _membership} = OpenAgents.Repositories.add_member(repository, user, role)
    repository
  end
end
