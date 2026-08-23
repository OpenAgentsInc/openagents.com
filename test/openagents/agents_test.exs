defmodule OpenAgents.AgentsTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Accounts
  alias OpenAgents.Agents
  alias OpenAgents.Agents.AgentToken
  alias OpenAgents.Repo

  test "registers an agent and exposes its credential only at registration" do
    assert {:ok, agent, credential} =
             Agents.register(%{
               "handle" => "release-bot",
               "display_name" => "Release bot",
               "registration_ip" => "192.0.2.10"
             })

    assert agent.handle == "release-bot"
    assert String.starts_with?(credential, "oa_agent_")
    assert {:ok, authenticated, token} = Agents.authenticate(credential)
    assert authenticated.id == agent.id
    assert token.scopes == ["agent:participate"]
    refute Repo.get_by(AgentToken, id: token.id).token_digest == credential
  end

  test "normalizes handles and rejects collisions, reserved, and confusable values" do
    assert {:ok, agent, _credential} =
             Agents.register(%{
               handle: "Build-Bot",
               display_name: "Build bot",
               registration_ip: "192.0.2.11"
             })

    assert agent.handle == "build-bot"

    assert {:error, :handle_taken} =
             Agents.register(%{
               handle: "build-bot",
               display_name: "Another bot",
               registration_ip: "192.0.2.12"
             })

    assert {:error, :confusable_handle} =
             Agents.register(%{
               handle: "12345",
               display_name: "Numeric bot",
               registration_ip: "192.0.2.13"
             })

    assert {:error, :confusable_handle} =
             Agents.register(%{
               handle: "build--bot",
               display_name: "Malformed bot",
               registration_ip: "192.0.2.14"
             })
  end

  test "suspension blocks authentication and credential minting" do
    {:ok, agent, credential} =
      Agents.register(%{
        handle: "suspendable-bot",
        display_name: "Suspendable bot",
        registration_ip: "192.0.2.15"
      })

    assert {:ok, suspended} = Agents.suspend(agent, "abuse review")
    assert suspended.status == "suspended"
    assert {:error, :invalid_agent_credential} = Agents.authenticate(credential)
    assert {:error, :agent_suspended} = Agents.mint_credential(suspended)
    assert {:ok, reinstated} = Agents.reinstate(suspended)
    assert {:ok, _agent, _token} = Agents.authenticate(credential)
    assert reinstated.status == "active"
  end

  test "link lifecycle is scoped to the agent and user" do
    {:ok, agent, _credential} =
      Agents.register(%{
        handle: "linkable-bot",
        display_name: "Linkable bot",
        registration_ip: "192.0.2.16"
      })

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: 991_016,
        github_login: "link-reviewer",
        github_avatar_url: "https://avatars.githubusercontent.com/u/991016?v=4"
      })

    assert {:ok, pending} = Agents.request_link(agent, user)
    assert pending.status == "pending"
    assert [listed] = Agents.list_pending_links(user)
    assert listed.id == pending.id

    assert {:ok, linked} = Agents.accept_link(user, pending.id)
    assert linked.status == "linked"
    assert {:ok, unlinked} = Agents.unlink(user, linked.id)
    assert unlinked.status == "unlinked"
    assert unlinked.agent_id == agent.id
  end

  test "agent can unlink a link and request it again after rejection or unlink" do
    {:ok, agent, _credential} =
      Agents.register(%{
        handle: "relinkable-bot",
        display_name: "Relinkable bot",
        registration_ip: "192.0.2.18"
      })

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: 991_018,
        github_login: "relink-reviewer",
        github_avatar_url: "https://avatars.githubusercontent.com/u/991018?v=4"
      })

    assert {:ok, pending} = Agents.request_link(agent, user)
    assert {:ok, rejected} = Agents.reject_link(user, pending.id)
    assert rejected.status == "rejected"
    assert {:ok, requested_again} = Agents.request_link(agent, user)
    assert requested_again.id == pending.id
    assert requested_again.status == "pending"
    assert {:ok, linked} = Agents.accept_link(user, requested_again.id)
    assert {:ok, unlinked} = Agents.unlink(agent, user)
    assert unlinked.id == linked.id
    assert unlinked.status == "unlinked"
    assert {:ok, requested_after_unlink} = Agents.request_link(agent, user)
    assert requested_after_unlink.id == linked.id
    assert requested_after_unlink.status == "pending"
  end

  test "rotates credentials while preserving the old credential" do
    {:ok, agent, old_credential} =
      Agents.register(%{
        handle: "rotating-bot",
        display_name: "Rotating bot",
        registration_ip: "192.0.2.19"
      })

    assert {:ok, token, new_credential} = Agents.mint_credential(agent, %{"name" => "rotated"})
    assert DateTime.compare(token.expires_at, DateTime.utc_now()) == :gt
    assert {:ok, old_agent, _old_token} = Agents.authenticate(old_credential)
    assert {:ok, new_agent, _new_token} = Agents.authenticate(new_credential)
    assert old_agent.id == agent.id
    assert new_agent.id == agent.id

    {:ok, _same_agent, old_token} = Agents.authenticate(old_credential)
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    old_token
    |> Ecto.Changeset.change(
      inserted_at: DateTime.add(expired_at, -1, :second),
      expires_at: expired_at
    )
    |> Repo.update!()

    assert {:error, :invalid_agent_credential} = Agents.authenticate(old_credential)
    assert {:ok, _same_agent, _token} = Agents.authenticate(new_credential)
  end

  test "refuses overlong registration fields without truncating" do
    assert {:error, :display_name_too_long} =
             Agents.register(%{
               handle: "long-name-bot",
               display_name: String.duplicate("x", 256),
               registration_ip: "192.0.2.20"
             })

    assert {:error, :description_too_long} =
             Agents.register(%{
               handle: "long-description-bot",
               display_name: "Long description bot",
               description: String.duplicate("x", 4_001),
               registration_ip: "192.0.2.21"
             })
  end

  test "agent credentials cannot authenticate with a human scope" do
    {:ok, _agent, credential} =
      Agents.register(%{
        handle: "scope-limited-bot",
        display_name: "Scope-limited bot",
        registration_ip: "192.0.2.17"
      })

    assert {:error, :invalid_agent_credential} = Agents.authenticate(credential, "forge:write")
  end
end
