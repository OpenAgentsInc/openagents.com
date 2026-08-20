defmodule OpenAgentsWeb.ComputersAccessTest do
  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Machines

  test "a signed-in owner cannot see or revoke another owner's computer", %{conn: conn} do
    owner = github_user("computers-record-owner")
    other_owner = github_user("computers-record-outsider")
    machine = pair!(owner, "private-box")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => other_owner.id})
    {:ok, view, _html} = live(conn, ~p"/computers")

    refute has_element?(view, "#computer-#{machine.id}")

    render_click(view, "revoke_machine", %{"id" => machine.id})

    assert has_element?(view, "#pairing-error", "Computer not found")
    refute has_element?(view, "#computer-#{machine.id}")
    assert {:ok, %{status: "active"}} = Machines.get_machine(owner.id, machine.id)
  end

  defp pair!(owner, name) do
    assert {:ok, pairing} =
             Machines.start_pairing(%{
               "name" => name,
               "tier" => "probe",
               "platform" => "linux-x64",
               "agent_version" => "0.4.0",
               "roots" => ["/home/test/work"]
             })

    assert {:ok, machine} = Machines.approve_pairing(owner, pairing.code)
    machine
  end
end
