defmodule OpenAgents.AccountsTest do
  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.Accounts
  alias OpenAgents.Conversations

  test "GitHub numeric identity is stable while login and avatar projections refresh" do
    assert {:ok, first} = Accounts.upsert_github_user(profile(91, "first-name"))

    assert {:ok, refreshed} =
             Accounts.upsert_github_user(
               profile(91, "renamed", "https://avatars.githubusercontent.com/u/91?v=5")
             )

    assert refreshed.id == first.id
    assert refreshed.github_id == 91
    assert refreshed.github_login == "renamed"
    assert refreshed.github_avatar_url == "https://avatars.githubusercontent.com/u/91?v=5"

    assert {:ok, other} = Accounts.upsert_github_user(profile(92, "other-name"))
    refute other.id == first.id
  end

  test "a ban survives GitHub profile refresh and fails active authorization closed" do
    assert {:ok, user} = Accounts.upsert_github_user(profile(101, "active-name"))
    assert {:ok, banned} = Accounts.ban_user(user, "manual_abuse_review")
    assert banned.status == "banned"
    assert banned.banned_at

    assert {:ok, refreshed} = Accounts.upsert_github_user(profile(101, "renamed-after-ban"))
    assert refreshed.id == user.id
    assert refreshed.github_login == "renamed-after-ban"
    assert refreshed.status == "banned"
    assert {:error, :banned} = Accounts.get_active_user(user.id)
  end

  test "one account owns one canonical conversation across browser sessions" do
    assert {:ok, user} = Accounts.upsert_github_user(profile(201, "same-person"))
    assert {:ok, first} = Conversations.ensure_conversation(user)
    assert {:ok, second} = Conversations.ensure_conversation(user)
    assert first.id == second.id

    assert {:ok, other} = Accounts.upsert_github_user(profile(202, "other-person"))
    assert {:ok, isolated} = Conversations.ensure_conversation(other)
    refute isolated.id == first.id

    assert Conversations.get_conversation_for_user(user).id == first.id
    assert Conversations.get_conversation_for_user(other).id == isolated.id
  end

  test "account-scoped turn limits aggregate across sessions sharing the user" do
    previous_limit = Application.fetch_env!(:openagents, :turn_rate_limit)
    Application.put_env(:openagents, :turn_rate_limit, 1)
    on_exit(fn -> Application.put_env(:openagents, :turn_rate_limit, previous_limit) end)

    assert {:ok, user} = Accounts.upsert_github_user(profile(301, "limited-person"))
    assert {:ok, first_browser_conversation} = Conversations.ensure_conversation(user)
    assert {:ok, _records} = Conversations.create_turn(first_browser_conversation, "First")

    assert {:ok, second_browser_conversation} = Conversations.ensure_conversation(user)
    assert second_browser_conversation.id == first_browser_conversation.id

    assert {:error, :rate_limited} =
             Conversations.create_turn(second_browser_conversation, "Second")
  end

  test "legacy browser rows remain isolated from authenticated accounts" do
    assert {:ok, legacy} = Conversations.ensure_conversation("legacy-browser-credential")
    assert {:ok, user} = Accounts.upsert_github_user(profile(401, "new-account"))
    assert {:ok, authenticated} = Conversations.ensure_conversation(user)

    refute authenticated.id == legacy.id
    assert Conversations.get_conversation_for_user(user).id == authenticated.id
    assert Conversations.get_conversation_for_browser("legacy-browser-credential").id == legacy.id
  end

  defp profile(id, login, avatar_url \\ nil) do
    %{
      github_id: id,
      github_login: login,
      github_avatar_url: avatar_url || "https://avatars.githubusercontent.com/u/#{id}?v=4"
    }
  end
end
