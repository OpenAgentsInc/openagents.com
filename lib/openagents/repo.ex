defmodule OpenAgents.Repo do
  use Ecto.Repo,
    otp_app: :openagents,
    adapter: Ecto.Adapters.Postgres

  def get_for_update!(queryable, id), do: get!(queryable, id, lock: true)
  def get_for_update!(queryable, id, opts), do: get!(queryable, id, [{:lock, true} | opts])
end
