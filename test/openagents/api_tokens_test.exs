defmodule OpenAgents.ApiTokensTest do
  use OpenAgents.DataCase, async: true

  alias OpenAgents.{Accounts, ApiTokens, AuditEvent, Repo}

  test "tokens are stored as digests, require scope, expire, and revoke" do
    {:ok, user} = Accounts.upsert_github_user(profile(801, "api-owner"))

    assert {:ok, token, plaintext} =
             ApiTokens.create(user, %{
               name: "automation",
               scopes: ["forge:write"],
               lifetime_days: 7
             })

    refute token.token_digest =~ plaintext

    assert %AuditEvent{actor_id: actor_id, metadata: %{"scopes" => ["forge:write"]}} =
             Repo.get_by!(AuditEvent, event_type: "api_token.created", subject_id: token.id)

    assert actor_id == user.id
    assert {:ok, authenticated, used} = ApiTokens.authenticate(plaintext, "forge:write")
    assert authenticated.id == user.id
    assert used.last_used_at
    assert {:error, :invalid_api_token} = ApiTokens.authenticate(plaintext, "computers:write")

    backdated = DateTime.add(DateTime.utc_now(), -2, :day)

    Repo.update_all(from(t in OpenAgents.ApiTokens.ApiToken, where: t.id == ^token.id),
      set: [inserted_at: backdated]
    )

    expired =
      Repo.get!(OpenAgents.ApiTokens.ApiToken, token.id)
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

    assert {:error, :invalid_api_token} = ApiTokens.authenticate(plaintext, "forge:write")

    fresh =
      expired
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), 1, :day))
      |> Repo.update!()

    assert {:ok, revoked} = ApiTokens.revoke(user, fresh.id)
    assert revoked.revoked_at
    assert {:error, :invalid_api_token} = ApiTokens.authenticate(plaintext, "forge:write")
  end

  test "invalid scopes and lifetimes fail closed" do
    {:ok, user} = Accounts.upsert_github_user(profile(802, "api-invalid"))

    assert {:error, :invalid_api_token} =
             ApiTokens.create(user, %{name: "too broad", scopes: ["admin"], lifetime_days: 1})

    assert {:error, :invalid_api_token} =
             ApiTokens.create(user, %{
               name: "too long",
               scopes: ["forge:write"],
               lifetime_days: 91
             })
  end

  defp profile(id, login) do
    %{
      github_id: id,
      github_login: login,
      github_avatar_url: "https://avatars.githubusercontent.com/u/#{id}?v=4"
    }
  end
end
