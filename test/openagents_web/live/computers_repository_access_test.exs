defmodule OpenAgentsWeb.ComputersRepositoryAccessTest do
  @moduledoc """
  REPOSITORY-001's computer principal, from the surface that grants it.

  `repository_machine_grants` was a complete, enforced authorization input with
  no writer outside tests: `OpenAgentsWeb.Plugs.ForgeGitAuth` accepted an
  `smct_` token, `OpenAgents.Forge.GitHTTP` routed it to
  `OpenAgents.Repositories.machine_access?/3`, and that predicate needed a row
  no route could create. So every Git request a paired computer made answered
  `404 unknown repository`, indistinguishable from an unauthorized one, and the
  tests passed because they inserted the row themselves.

  These prove the grant is reachable and scoped. The enforcement itself — a
  real `git clone` and `git push` over HTTP with the computer's own credential,
  admitted only for the operations granted — is
  `OpenAgents.Forge.GitHTTPTest`, which now obtains its grant through this same
  entry point rather than through a context function nothing called.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OpenAgents.Machines
  alias OpenAgents.Repositories

  defp owner(login), do: repository_user_fixture(login)

  defp repository!(user, name) do
    {:ok, repository, :created} =
      Repositories.create_user_repository(user, %{name: name}, "grant-#{name}-#{user.id}")

    repository
    |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
    |> OpenAgents.Repo.update!()
  end

  defp computer!(user, name) do
    {:ok, pairing} =
      Machines.start_pairing(%{
        "name" => name,
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.4.0",
        "roots" => ["/home/test/work"]
      })

    {:ok, machine} = Machines.approve_pairing(user, pairing.code)
    machine
  end

  defp session(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  test "the owner grants and withdraws a computer's repository access", %{conn: conn} do
    user = owner("grant-owner")
    repository = repository!(user, "granted")
    machine = computer!(user, "grant-box")

    refute Repositories.machine_access?(repository, machine.id, "read")

    {:ok, view, _html} = live(session(conn, user), ~p"/computers")

    assert has_element?(view, "#repository-access-#{machine.id}", "No repositories granted")

    view
    |> form("#repository-grant-form-#{machine.id}",
      grant: %{machine_id: machine.id, repository_id: repository.id, operations: "read"}
    )
    |> render_submit()

    assert has_element?(view, "#repository-grant-success", "read")

    assert has_element?(
             view,
             "#grant-#{machine.id}-#{repository.id}",
             "#{repository.owner}/granted"
           )

    # The predicate `OpenAgents.Forge.GitHTTP` calls for a `{:machine, id}`
    # principal, which nothing could satisfy before.
    assert Repositories.machine_access?(repository, machine.id, "read")
    refute Repositories.machine_access?(repository, machine.id, "write")

    view
    |> form("#repository-grant-form-#{machine.id}",
      grant: %{machine_id: machine.id, repository_id: repository.id, operations: "write"}
    )
    |> render_submit()

    assert Repositories.machine_access?(repository, machine.id, "write")

    view |> element("#revoke-grant-#{machine.id}-#{repository.id}") |> render_click()

    assert has_element?(view, "#repository-grant-revoked")
    refute Repositories.machine_access?(repository, machine.id, "read")
    refute has_element?(view, "#grant-#{machine.id}-#{repository.id}")
  end

  test "the withdrawal is audited with the account that created the grant", %{conn: conn} do
    user = owner("grant-audit")
    repository = repository!(user, "audited")
    machine = computer!(user, "audit-box")

    {:ok, view, _html} = live(session(conn, user), ~p"/computers")

    view
    |> form("#repository-grant-form-#{machine.id}",
      grant: %{machine_id: machine.id, repository_id: repository.id, operations: "read"}
    )
    |> render_submit()

    view |> element("#revoke-grant-#{machine.id}-#{repository.id}") |> render_click()

    events =
      OpenAgents.Repo.all(
        from event in OpenAgents.AuditEvent,
          where: event.repository_id == ^repository.id,
          order_by: [asc: event.inserted_at]
      )

    types = Enum.map(events, & &1.event_type)
    assert "repository.machine_grant.updated" in types
    assert "repository.machine_grant.revoked" in types

    revoked = Enum.find(events, &(&1.event_type == "repository.machine_grant.revoked"))
    assert revoked.metadata["machine_id"] == machine.id
    assert revoked.metadata["granted_by_user_id"] == user.id
  end

  test "a computer another account owns is not selectable and not grantable", %{conn: conn} do
    user = owner("grant-scope-owner")
    stranger = owner("grant-scope-stranger")
    repository = repository!(user, "scoped")
    foreign = computer!(stranger, "foreign-box")
    own = computer!(user, "own-box")

    {:ok, view, _html} = live(session(conn, user), ~p"/computers")

    refute has_element?(view, "#repository-access-#{foreign.id}")

    # A LiveView event carries whatever the client sends. The computer is
    # resolved through the acting account, so a foreign identifier refuses
    # exactly as an absent one does (IDENTITY-002).
    render_submit(view, "grant_repository_access", %{
      "grant" => %{
        "machine_id" => foreign.id,
        "repository_id" => repository.id,
        "operations" => "write"
      }
    })

    assert has_element?(view, "#pairing-error", "Computer not found")
    refute Repositories.machine_access?(repository, foreign.id, "read")
    refute Repositories.machine_access?(repository, own.id, "read")
  end

  test "a repository this account does not administer refuses the same way", %{conn: conn} do
    user = owner("grant-repo-scope")
    stranger = owner("grant-repo-stranger")
    foreign_repository = repository!(stranger, "not-mine")
    machine = computer!(user, "scoped-box")

    {:ok, repository, :created} =
      Repositories.create_user_repository(user, %{name: "mine"}, "grant-mine-#{user.id}")

    {:ok, view, _html} = live(session(conn, user), ~p"/computers")

    # The picker offers only repositories this account administers.
    assert has_element?(view, "#grant-repository-#{machine.id} option[value='#{repository.id}']")

    refute has_element?(
             view,
             "#grant-repository-#{machine.id} option[value='#{foreign_repository.id}']"
           )

    render_submit(view, "grant_repository_access", %{
      "grant" => %{
        "machine_id" => machine.id,
        "repository_id" => foreign_repository.id,
        "operations" => "write"
      }
    })

    assert has_element?(view, "#pairing-error", "do not administer")
    refute Repositories.machine_access?(foreign_repository, machine.id, "read")
  end

  test "a viewer membership cannot hand a repository to a computer", %{conn: conn} do
    holder = owner("grant-role-owner")
    viewer = owner("grant-role-viewer")
    repository = repository!(holder, "role-scoped")
    {:ok, _membership} = Repositories.add_member(repository, viewer, "viewer")
    machine = computer!(viewer, "viewer-box")

    assert {:error, :repository_not_allowed} =
             Repositories.grant_machine_access(viewer, machine.id, repository.id, ["read"])

    {:ok, view, _html} = live(session(conn, viewer), ~p"/computers")

    refute has_element?(view, "#grant-repository-#{machine.id} option[value='#{repository.id}']")
    refute Repositories.machine_access?(repository, machine.id, "read")
  end

  test "reading and withdrawing a grant are scoped to the account that owns the computer" do
    holder = owner("grant-cross-holder")
    admin = owner("grant-cross-admin")

    # One repository both accounts administer, and a computer only `holder`
    # owns. The repository membership is not authority over someone else's
    # computer, in either direction.
    repository = repository!(holder, "shared-admin")
    {:ok, _membership} = Repositories.add_member(repository, admin, "maintainer")
    machine = computer!(holder, "cross-box")

    assert {:ok, _grant} =
             Repositories.grant_machine_access(holder, machine.id, repository.id, ["read"])

    assert [_one] = Repositories.list_machine_grants(holder, machine.id)
    assert Repositories.list_machine_grants(admin, machine.id) == []

    assert {:error, :machine_not_owned} =
             Repositories.revoke_machine_access(admin, machine.id, repository.id)

    assert Repositories.machine_access?(repository, machine.id, "read")

    assert {:ok, _revoked} =
             Repositories.revoke_machine_access(holder, machine.id, repository.id)

    refute Repositories.machine_access?(repository, machine.id, "read")
  end

  test "revoking the computer ends every grant it holds without deleting them", %{conn: conn} do
    user = owner("grant-revoked-computer")
    repository = repository!(user, "still-granted")
    machine = computer!(user, "revoked-grant-box")

    {:ok, view, _html} = live(session(conn, user), ~p"/computers")

    view
    |> form("#repository-grant-form-#{machine.id}",
      grant: %{machine_id: machine.id, repository_id: repository.id, operations: "write"}
    )
    |> render_submit()

    assert Repositories.machine_access?(repository, machine.id, "write")

    view |> element("#revoke-#{machine.id}") |> render_click()

    refute Repositories.machine_access?(repository, machine.id, "read")
    assert [_grant] = Repositories.list_machine_grants(user, machine.id)
  end
end
