defmodule OpenAgents.Repo.Migrations.AllowDeploymentsPromoteApiTokenScope do
  use Ecto.Migration

  # The allowed-scope list stays deny-by-default: it names every scope a
  # credential may carry, and `deployments:promote` is admitted here only so
  # that operator fleet promotion has a scope of its own. Nothing about
  # admitting it here decides who may be issued one; `OpenAgents.ApiTokens`
  # still refuses the scope to a non-operator.
  def up do
    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check:
               "scopes <@ ARRAY['chat:account', 'forge:write', 'deployments:write', 'deployments:promote', 'box:control', 'computer:control']::varchar[]"
           )
  end

  def down do
    execute "DELETE FROM api_tokens WHERE 'deployments:promote' = ANY(scopes)"

    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check:
               "scopes <@ ARRAY['chat:account', 'forge:write', 'deployments:write', 'box:control', 'computer:control']::varchar[]"
           )
  end
end
