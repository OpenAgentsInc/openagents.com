defmodule OpenAgents.Repo.Migrations.AllowBoxControlApiTokenScope do
  use Ecto.Migration

  def change do
    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check:
               "scopes <@ ARRAY['chat:account', 'forge:write', 'deployments:write', 'box:control']::varchar[]"
           )
  end
end
