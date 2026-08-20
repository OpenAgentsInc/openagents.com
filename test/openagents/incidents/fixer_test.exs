defmodule OpenAgents.Incidents.FixerTest do
  use OpenAgents.DataCase

  alias OpenAgents.Incidents
  alias OpenAgents.Incidents.Fixer
  alias OpenAgents.{Accounts, Conversations, Repo}

  test "is a no-op while autonomous fixing is disabled" do
    refute Fixer.enabled?()
    {:ok, incident} = anomalous_incident("fixer-off")
    assert {:ok, :skipped} = Fixer.maybe_spawn(incident)
    assert is_nil(Repo.reload(incident).fixer_job_id)
  end

  test "even when enabled, skips an incident with no paired machine to work on" do
    Application.put_env(:openagents, :incident_fixer_enabled, true)
    on_exit(fn -> Application.put_env(:openagents, :incident_fixer_enabled, false) end)

    {:ok, incident} = anomalous_incident("fixer-no-machine")
    # No machine is paired for this owner, so there is nothing to delegate to.
    assert {:ok, :skipped} = Fixer.maybe_spawn(incident)
    assert is_nil(Repo.reload(incident).fixer_job_id)
  end

  test "even when enabled, never fixes a failed background job (no recursion)" do
    Application.put_env(:openagents, :incident_fixer_enabled, true)
    on_exit(fn -> Application.put_env(:openagents, :incident_fixer_enabled, false) end)

    {:ok, incident} = anomalous_incident("fixer-job-origin", origin: "job_server", surface: "job")
    assert {:ok, :skipped} = Fixer.maybe_spawn(incident)
  end

  defp anomalous_incident(login, overrides \\ []) do
    scope = owner_scope(login)

    Incidents.record(
      Enum.into(overrides, %{
        conversation_id: scope.conversation.id,
        owner_user_id: scope.user.id,
        owner_visitor_id: scope.owner.id,
        surface: "text",
        origin: "turn_server",
        code: "invalid_provider_event"
      })
    )
  end

  defp owner_scope(login) do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)
    %{user: user, owner: owner, conversation: conversation}
  end
end
