defmodule OpenAgents.Repo.Migrations.AllowNonExpiringAccountApiTokens do
  use Ecto.Migration

  def up do
    drop constraint(:api_tokens, :api_tokens_expiry_after_creation)
    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    alter table(:api_tokens) do
      modify :expires_at, :utc_datetime_usec, null: true
    end

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check: "scopes <@ ARRAY['account:write', 'forge:write']::varchar[]"
           )

    create constraint(:api_tokens, :api_tokens_expiry_after_creation,
             check: "expires_at IS NULL OR expires_at > inserted_at"
           )
  end

  def down do
    drop constraint(:api_tokens, :api_tokens_expiry_after_creation)
    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    execute("DELETE FROM api_tokens WHERE expires_at IS NULL OR 'account:write' = ANY(scopes)")

    alter table(:api_tokens) do
      modify :expires_at, :utc_datetime_usec, null: false
    end

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check: "scopes <@ ARRAY['forge:write']::varchar[]"
           )

    create constraint(:api_tokens, :api_tokens_expiry_after_creation,
             check: "expires_at > inserted_at"
           )
  end
end
