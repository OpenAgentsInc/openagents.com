defmodule OpenAgentsWeb.ComputersPairingErrorsTest do
  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Machines

  test "expired pairing codes produce the specific recovery message", %{conn: conn} do
    user = github_user("computers-expired-code")
    pairing = start_pairing!("expired-box")

    pairing.pairing
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> OpenAgents.Repo.update!()

    {:ok, view, _html} = live(as_user(conn, user), ~p"/computers")
    submit_code(view, pairing.code)

    assert has_element?(view, "#pairing-error", "That pairing code expired")
    assert has_element?(view, "#pairing-form")
  end

  test "consumed pairing codes cannot create a second computer", %{conn: conn} do
    first_owner = github_user("computers-consumed-first")
    current_user = github_user("computers-consumed-current")
    pairing = start_pairing!("single-use-box")
    assert {:ok, _machine} = Machines.approve_pairing(first_owner, pairing.code)

    {:ok, view, _html} = live(as_user(conn, current_user), ~p"/computers")
    submit_code(view, pairing.code)

    assert has_element?(view, "#pairing-error", "That pairing code was already used")
    refute has_element?(view, "#computers-list .computer-card")
    assert Machines.list_machines(current_user.id) == []
  end

  test "a full account receives the capacity outcome and keeps all eight rows", %{conn: conn} do
    user = github_user("computers-capacity-message")

    machines =
      for index <- 1..8 do
        pairing = start_pairing!("full-box-#{index}")
        assert {:ok, machine} = Machines.approve_pairing(user, pairing.code)
        machine
      end

    ninth = start_pairing!("full-box-9")
    {:ok, view, _html} = live(as_user(conn, user), ~p"/computers")
    submit_code(view, ninth.code)

    assert has_element?(view, "#pairing-error", "Computer limit reached")
    assert Enum.all?(machines, &has_element?(view, "#computer-#{&1.id}"))
    assert length(Machines.list_machines(user.id)) == 8
  end

  test "the submit fence and single-use code prevent duplicate records", %{conn: conn} do
    user = github_user("computers-duplicate-submit")
    pairing = start_pairing!("only-once-box")
    {:ok, view, _html} = live(as_user(conn, user), ~p"/computers")

    assert has_element?(view, "#approve-pairing[phx-disable-with='Pairing…']")
    submit_code(view, pairing.code)
    submit_code(view, pairing.code)

    assert has_element?(view, "#pairing-error", "That pairing code was already used")
    assert [%{name: "only-once-box"}] = Machines.list_machines(user.id)
    assert has_element?(view, "#computers-list .computer-card")
    refute has_element?(view, "#computers-list .computer-card + .computer-card")
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp submit_code(view, code) do
    view
    |> form("#pairing-form", pairing: %{code: code})
    |> render_submit()
  end

  defp start_pairing!(name) do
    assert {:ok, pairing} =
             Machines.start_pairing(%{
               "name" => name,
               "tier" => "curated",
               "platform" => "linux-x64",
               "agent_version" => "0.4.0",
               "roots" => ["/home/test/work"]
             })

    pairing
  end
end
