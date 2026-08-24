defmodule OpenAgents.Inference.ComputerRevocationTest do
  @moduledoc """
  IDENTITY-008's authority clause: a revoked computer holds no inference
  authority.

  `inference_grants.machine_id` was written by
  `OpenAgents.Work.DelegationServer` and read by nothing, and the absence was
  the bug. Revoking a computer closed its channel and finished its assignments
  and left its grants `active` — each one a plaintext token already delivered to
  that computer, and `OpenAgentsWeb.InferenceProxyController` authenticates the
  token and never the computer.

  Two properties, because they fail differently.

  **Outstanding grants stop working.** The sweep runs in the same transaction
  that writes the revoked computer row, so a grant minted before the decision is
  terminal the moment the decision commits.

  **A grant minted inside the window does not survive it.** Ecto's sandbox runs
  each test inside one uncommitted transaction, so a mint attempted after
  `revoke_machine/2` returns here is a mint attempted after the revocation
  decided and before it committed — the window itself, not a model of it. It is
  refused twice: by `OpenAgents.Inference.mint/1`, and, with that call bypassed,
  by `inference_grants_refuse_revoked_computer` in PostgreSQL.

  What that pair does not show is a mint on a *different* connection blocking
  until the revocation commits. That rests on the `FOR SHARE` the trigger takes
  on the computer row, which conflicts with the `FOR NO KEY UPDATE` an ordinary
  `UPDATE machines` takes. The last test asserts that lock is in the deployed
  trigger, read back from `pg_get_functiondef` rather than from the migration
  file.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query

  alias OpenAgents.Inference
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Machines
  alias OpenAgents.Repo

  defp computer(owner, key) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "revocation-#{key}",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/home/x/code"]
      })

    {:ok, machine} = Machines.approve_pairing(owner, code)
    machine
  end

  defp scope(key) do
    owner = github_user("revoke-#{key}")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

    %{
      owner: owner,
      owner_visitor_id: conversation.visitor_id,
      conversation_id: conversation.id,
      machine: computer(owner, key)
    }
  end

  defp mint!(scope, machine) do
    {:ok, grant, token} =
      Inference.mint(%{
        owner_visitor_id: scope.owner_visitor_id,
        conversation_id: scope.conversation_id,
        machine_id: machine.id
      })

    {grant, token}
  end

  describe "an outstanding grant does not outlive its computer" do
    test "every grant the revoked computer holds becomes terminal" do
      scope = scope("outstanding")
      {first, first_token} = mint!(scope, scope.machine)
      {second, second_token} = mint!(scope, scope.machine)

      assert {:ok, %Grant{}} = Inference.resolve(first_token)
      assert {:ok, %Grant{}} = Inference.resolve(second_token)

      assert {:ok, revoked} = Machines.revoke_machine(scope.owner, scope.machine.id)
      assert revoked.status == "revoked"

      assert {:error, :grant_revoked} = Inference.resolve(first_token)
      assert {:error, :grant_revoked} = Inference.resolve(second_token)

      for id <- [first.id, second.id] do
        stored = Repo.get(Grant, id)
        assert stored.status == "revoked"
        assert stored.revoked_at
      end
    end

    test "the proxy refuses the revoked computer's token", %{conn: conn} do
      scope = scope("proxy")
      {_grant, token} = mint!(scope, scope.machine)

      assert {:ok, _revoked} = Machines.revoke_machine(scope.owner, scope.machine.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/api/inference/proxy",
          Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "still here?"}]})
        )

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "grant_revoked"}}
    end

    test "revocation ends authority without touching the fence THREAD-001 requires" do
      scope = scope("fence")
      {grant, _token} = mint!(scope, scope.machine)

      assert {:ok, _revoked} = Machines.revoke_machine(scope.owner, scope.machine.id)

      stored = Repo.get(Grant, grant.id)
      assert stored.status == "revoked"
      assert stored.conversation_id == scope.conversation_id
      assert is_nil(stored.thread_id)
      assert stored.machine_id == scope.machine.id
    end

    test "revocation reaches only the revoked computer's grants" do
      scope = scope("neighbour")
      other = computer(scope.owner, "neighbour-other")

      {_revoked_grant, revoked_token} = mint!(scope, scope.machine)
      {_kept_grant, kept_token} = mint!(scope, other)

      {:ok, _machineless, machineless_token} =
        Inference.mint(%{
          owner_visitor_id: scope.owner_visitor_id,
          conversation_id: scope.conversation_id
        })

      assert {:ok, _} = Machines.revoke_machine(scope.owner, scope.machine.id)

      assert {:error, :grant_revoked} = Inference.resolve(revoked_token)
      assert {:ok, %Grant{status: "active"}} = Inference.resolve(kept_token)
      assert {:ok, %Grant{status: "active"}} = Inference.resolve(machineless_token)
    end

    test "an expired pairing revokes its computer's grants on the same path" do
      owner = github_user("revoke-pairing")
      {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

      {:ok, %{pairing: pairing, code: code, poll_secret: poll_secret}} =
        Machines.start_pairing(%{
          "name" => "revocation-pairing",
          "tier" => "curated",
          "platform" => "linux-x64",
          "agent_version" => "0.1.0",
          "roots" => ["/home/x/code"]
        })

      {:ok, machine} = Machines.approve_pairing(owner, code)

      {:ok, _grant, token} =
        Inference.mint(%{
          owner_visitor_id: conversation.visitor_id,
          conversation_id: conversation.id,
          machine_id: machine.id
        })

      # Expire the pairing so the claim takes the expiry branch, which revokes
      # the computer it already created.
      Repo.update_all(
        from(p in OpenAgents.Machines.Pairing, where: p.id == ^pairing.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:error, :pairing_expired} = Machines.claim_pairing(pairing.id, poll_secret)
      assert Repo.get(OpenAgents.Machines.Machine, machine.id).status == "revoked"
      assert {:error, :grant_revoked} = Inference.resolve(token)
    end
  end

  describe "a grant minted inside the revocation window does not survive it" do
    test "mint/1 refuses and writes nothing" do
      scope = scope("window")

      # The sandbox holds this test in one uncommitted transaction, so the
      # revocation below has decided and has not committed. This is the window.
      assert {:ok, _revoked} = Machines.revoke_machine(scope.owner, scope.machine.id)

      before = Repo.aggregate(Grant, :count)

      assert {:error, :machine_revoked} =
               Inference.mint(%{
                 owner_visitor_id: scope.owner_visitor_id,
                 conversation_id: scope.conversation_id,
                 machine_id: scope.machine.id
               })

      assert Repo.aggregate(Grant, :count) == before
    end

    test "PostgreSQL refuses the same insert with mint/1 bypassed" do
      scope = scope("window-db")
      assert {:ok, _revoked} = Machines.revoke_machine(scope.owner, scope.machine.id)

      attrs = %{
        owner_visitor_id: scope.owner_visitor_id,
        conversation_id: scope.conversation_id,
        machine_id: scope.machine.id,
        model_id: "test-model",
        token_digest: :crypto.hash(:sha256, "sig_bypass"),
        max_total_tokens: 100,
        max_calls: 1,
        max_cost_microusd: 100,
        expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
      }

      error =
        assert_raise Postgrex.Error, fn ->
          attrs |> Grant.mint_changeset() |> Repo.insert()
        end

      assert error.postgres.message =~ "cannot name computer"
      assert error.postgres.message =~ "revoked"
    end

    test "the deployed guard reads the computer row under a conflicting lock" do
      %Postgrex.Result{rows: [[definition]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT pg_get_functiondef('inference_grants_refuse_revoked_computer'::regproc)",
          []
        )

      assert definition =~ "FROM machines"
      # FOR SHARE conflicts with the FOR NO KEY UPDATE an ordinary
      # `UPDATE machines SET status = 'revoked'` takes; the foreign key's own
      # FOR KEY SHARE does not, and would leave the two free to interleave.
      assert definition =~ "FOR SHARE"
    end
  end
end
