defmodule OpenAgentsWeb.ComputersLiveTest do
  use OpenAgentsWeb.SarahConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Computer
  alias OpenAgents.Machines

  test "shows a pairing path and an honest empty state", %{conn: conn} do
    conn = log_in_github_user(conn, "computers-empty")
    {:ok, view, _html} = live(conn, ~p"/computers")

    assert has_element?(view, "#pairing-card")
    assert has_element?(view, "#pairing-form")
    assert has_element?(view, "#computers-empty.hidden.only\\:block")
    assert has_element?(view, "#computers-list-heading")
    refute has_element?(view, "#computers-list .computer-card")
  end

  test "pairs a computer, resets the form, and updates the stream", %{conn: conn} do
    user = github_user("computers-pair")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    pairing = start_pairing!("pairing-laptop")
    {:ok, view, _html} = live(conn, ~p"/computers")

    view
    |> form("#pairing-form", pairing: %{code: pairing.code})
    |> render_submit()

    assert has_element?(view, "#pairing-success", "pairing-laptop")
    assert has_element?(view, "#computer-#{paired_machine!(user).id}[data-presence=offline]")
    assert has_element?(view, "#computers-empty.hidden.only\\:block")
    assert has_element?(view, "#pairing_code[value='']")
  end

  test "renders typed pairing failures without replacing the form", %{conn: conn} do
    conn = log_in_github_user(conn, "computers-pair-error")
    {:ok, view, _html} = live(conn, ~p"/computers")

    view
    |> form("#pairing-form", pairing: %{code: "NOPE-1234"})
    |> render_submit()

    assert has_element?(view, "#pairing-error", "No pairing found")
    assert has_element?(view, "#pairing-form")
    refute has_element?(view, "#pairing-success")
  end

  test "presence and last-seen updates arrive without a page refresh", %{conn: conn} do
    user = github_user("computers-presence")
    machine = pair!(user, "presence-box")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, _html} = live(conn, ~p"/computers")

    assert has_element?(
             view,
             "#computer-#{machine.id}[data-state=active][data-presence=offline]",
             "Offline"
           )

    assert {:ok, _owner} = Computer.register(machine.id)
    _state = :sys.get_state(view.pid)
    assert has_element?(view, "#computer-#{machine.id}[data-presence=online]", "Online")

    assert {:ok, _updated} =
             Machines.store_probe(machine, %{
               "platform" => "linux",
               "acp_agents" => [
                 %{
                   "id" => "codex",
                   "model" => "gpt-5.6-sol",
                   "reasoning_effort" => "medium",
                   "mode" => "agent-full-access"
                 }
               ]
             })

    _state = :sys.get_state(view.pid)
    assert has_element?(view, "#computer-#{machine.id} time[datetime]")

    assert has_element?(
             view,
             "#computer-agent-#{machine.id}",
             "gpt-5.6-sol · medium · agent-full-access"
           )

    assert :ok = Computer.unregister(machine.id)
    _state = :sys.get_state(view.pid)
    assert has_element?(view, "#computer-#{machine.id}[data-presence=offline]", "Offline")
  end

  test "revocation is confirmed, disconnects access, and announces its own outcome", %{conn: conn} do
    user = github_user("computers-revoke")
    machine = pair!(user, "revoked-box")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, _html} = live(conn, ~p"/computers")

    assert has_element?(
             view,
             "#revoke-#{machine.id}[data-confirm][phx-disable-with='Revoking…']",
             "Revoke access"
           )

    view |> element("#revoke-#{machine.id}") |> render_click()

    assert has_element?(view, "#revocation-success", "revoked-box")
    assert has_element?(view, "#revocation-success [data-title]", "REVOKED")
    assert has_element?(view, "#computer-#{machine.id}[data-state=revoked]")
    refute has_element?(view, "#revoke-#{machine.id}")
  end

  test "feature-disabled environments keep management honest", %{conn: conn} do
    previous = Application.fetch_env!(:openagents, :computer_controller_enabled)
    Application.put_env(:openagents, :computer_controller_enabled, false)
    on_exit(fn -> Application.put_env(:openagents, :computer_controller_enabled, previous) end)

    user = github_user("computers-disabled")
    machine = pair!(user, "existing-box")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, _html} = live(conn, ~p"/computers")

    assert has_element?(view, "#computer-controller-disabled", "New pairing codes are disabled")
    refute has_element?(view, "#pairing-form")
    assert has_element?(view, "#computer-#{machine.id}")
    assert has_element?(view, "#revoke-#{machine.id}")
  end

  defp paired_machine!(user) do
    [machine] = Machines.list_machines(user.id)
    machine
  end

  defp pair!(user, name) do
    pairing = start_pairing!(name)
    assert {:ok, machine} = Machines.approve_pairing(user, pairing.code)
    machine
  end

  defp start_pairing!(name) do
    assert {:ok, pairing} =
             Machines.start_pairing(%{
               "name" => name,
               "tier" => "curated",
               "platform" => "linux-x64",
               "agent_version" => "0.4.0",
               "roots" => ["/home/sarah/work"]
             })

    pairing
  end
end
