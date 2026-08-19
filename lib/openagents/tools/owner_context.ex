defmodule OpenAgents.Tools.OwnerContext do
  @moduledoc false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Repo
  alias OpenAgents.Tools.ExecutionContext

  @doc "Resolves the signed-in owner behind a browser conversation."
  def resolve(%ExecutionContext{owner_visitor_id: visitor_id}) when is_binary(visitor_id) do
    with {:ok, _id} <- Ecto.UUID.cast(visitor_id),
         %Visitor{user_id: user_id} when is_binary(user_id) <- Repo.get(Visitor, visitor_id),
         %User{status: "active"} = user <- Repo.get(User, user_id) do
      {:ok, user}
    else
      _unavailable -> {:error, :owner_not_signed_in}
    end
  end

  def resolve(_context), do: {:error, :owner_not_signed_in}
end
