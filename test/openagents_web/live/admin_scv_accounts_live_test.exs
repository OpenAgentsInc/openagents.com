defmodule OpenAgentsWeb.AdminScvAccountsLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.SCV.CodexAccounts

  describe "access" do
    test "an operator can open the SCV Codex account surface", %{conn: conn} do
      conn = log_in_admin_user(conn, "scv-codex-operator")
      {:ok, view, _html} = live(conn, ~p"/admin/scv/accounts")

      assert has_element?(view, "#admin-scv-accounts-page")
      assert has_element?(view, "#codex-account-form")
      assert has_element?(view, "#codex-service-accounts-later")
    end

    test "ordinary and anonymous users are redirected without disclosure", %{conn: conn} do
      ordinary = log_in_github_user(conn, "scv-codex-ordinary")

      assert {:error, {:redirect, %{to: "/"}}} = live(ordinary, ~p"/admin/scv/accounts")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/scv/accounts")
    end
  end

  test "starts the device flow and replaces the one-time code with verified account state", %{
    conn: conn
  } do
    conn = log_in_admin_user(conn, "scv-codex-connect")
    {:ok, view, _html} = live(conn, ~p"/admin/scv/accounts")
    :ok = CodexAccounts.subscribe()

    view
    |> form("#codex-account-form", account: %{label: "Primary Codex"})
    |> render_submit()

    assert has_element?(view, "#codex-device-login")
    assert has_element?(view, "#codex-device-code", "TEST-CODE")

    assert has_element?(
             view,
             "#open-codex-device-login[href='https://auth.openai.com/codex/device']"
           )

    assert_receive {:scv_codex_accounts, {:account_ready, _account_id}}, 5_000
    _state = :sys.get_state(view.pid)

    assert has_element?(view, "#codex-accounts li", "Primary Codex")
    assert has_element?(view, "#codex-accounts", "gpt-5.6-luna")
    refute has_element?(view, "#codex-device-login")
  end
end
