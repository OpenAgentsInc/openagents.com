defmodule OpenAgents.Tools.GitHubContext do
  @moduledoc false

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Repo
  alias OpenAgents.Tools.ExecutionContext

  @doc "Resolves the signed-in owner's GitHub token. The token never leaves the server."
  def resolve(%ExecutionContext{owner_visitor_id: visitor_id}) when is_binary(visitor_id) do
    with {:ok, _id} <- Ecto.UUID.cast(visitor_id),
         %Visitor{user_id: user_id} when is_binary(user_id) <- Repo.get(Visitor, visitor_id),
         %User{status: "active"} = user <- Repo.get(User, user_id),
         {:ok, token} <- Accounts.github_token(user) do
      {:ok, token, user}
    else
      _unavailable -> {:error, :github_not_connected}
    end
  end

  def resolve(_context), do: {:error, :github_not_connected}
end
