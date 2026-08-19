defmodule OpenAgents.Repo do
  use Ecto.Repo,
    otp_app: :openagents,
    adapter: Ecto.Adapters.Postgres
end
