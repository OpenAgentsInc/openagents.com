defmodule OpenAgents.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def up do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_digest, :binary, null: false
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token_digest])
    create index(:api_tokens, [:user_id, :inserted_at])
    create constraint(:api_tokens, :api_tokens_scopes_present, check: "cardinality(scopes) > 0")

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check: "scopes <@ ARRAY['forge:write']::varchar[]"
           )

    create constraint(:api_tokens, :api_tokens_expiry_after_creation,
             check: "expires_at > inserted_at"
           )

    create constraint(:api_tokens, :api_tokens_digest_length,
             check: "octet_length(token_digest) = 32"
           )
  end

  def down do
    drop table(:api_tokens)
  end
end
