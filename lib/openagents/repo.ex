defmodule OpenAgents.Repo do
  use Ecto.Repo,
    otp_app: :openagents,
    adapter: Ecto.Adapters.Postgres

  def get_for_update!(queryable, id), do: get!(queryable, id, lock: true)
  def get_for_update!(queryable, id, opts), do: get!(queryable, id, [{:lock, true} | opts])

  def get_for_update(queryable, id), do: get(queryable, id, lock: true)
  def get_for_update(queryable, id, opts), do: get(queryable, id, [{:lock, true} | opts])

  def get_by_for_update(queryable, clauses), do: get_by(queryable, clauses, lock: true)

  def get_by_for_update(queryable, clauses, opts),
    do: get_by(queryable, clauses, [{:lock, true} | opts])
end
