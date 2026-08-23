defmodule OpenAgents.Repo.Migrations.AllowDeploymentsWriteApiTokenScope do
  use Ecto.Migration

  def up do
    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check:
               "scopes <@ ARRAY['chat:account', 'forge:write', 'deployments:write']::varchar[]"
           )
  end

  def down do
    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check: "scopes <@ ARRAY['chat:account', 'forge:write']::varchar[]"
           )
  end
end
