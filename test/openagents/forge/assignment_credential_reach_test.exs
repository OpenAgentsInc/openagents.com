defmodule OpenAgents.Forge.AssignmentCredentialReachTest do
  @moduledoc """
  The executable enumeration behind IDENTITY-010's list of sinks.

  IDENTITY-010 says the plaintext Computer assignment credential exists only in
  memory while the delegation starts, and is not persisted in a job, journal,
  prompt, output, shell environment, global Git configuration, or API response.
  That is a list of seven places someone thought of.
  `computer_control_api_test.exs` checks two of them — the create response and
  one job's report column — so a sink added later is outside what any proof
  here examines, and the credential leaking is the failure the list exists to
  prevent.

  This file enumerates the sinks rather than the absences, two ways.

  1. **Who can hold one.** The plaintext comes into existence in exactly one
     place, `OpenAgents.Forge.Assignments.persist_assignment/7`, and leaves that
     module through `create/1` and through
     `OpenAgents.Forge.AssignmentCredentialVault`. Every module that can hold
     one therefore carries a compiled import edge to one of those functions, and
     the edges are read from BEAM import tables rather than from source text,
     so a comment cannot add a caller and a rename cannot hide one.

  2. **Where one could land.** A real delegation is driven end to end with a
     real minted credential, and then every base table in the database is asked
     whether any row of it renders that credential. The population is
     PostgreSQL's own catalog, which cannot forget a table or a column, so a
     projection, a journal, or an audit row added tomorrow is scanned the day it
     lands rather than the day someone remembers it. The same run asserts the
     credential appears exactly once in the `agent` frame — under
     `assignment_credential` and under no other key — and in no log line
     emitted while the delegation runs.

  A positive control asserts the scanner can see a value that *is* persisted, so
  a scan that silently matched nothing would fail rather than pass.

  **What this does not close.** The shell environment and the global Git
  configuration in IDENTITY-010's list are on the delegated Computer, past this
  application's boundary; what is proven here is that the server puts the
  credential in one frame field and nowhere else. IDENTITY-010 records that.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog, only: [with_log: 1]
  import OpenAgents.AccountsFixtures

  alias OpenAgents.ApiTokens
  alias OpenAgents.Forge.{AssignmentCredentialVault, Assignments}
  alias OpenAgents.Issues
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.Support.FakeController
  alias OpenAgents.Work

  @root "/tmp/openagents-assignment-credential-reach"

  # `config/test.exs` sets the primary log level to `:warning`, so an
  # `info` or `debug` line carrying the credential would never reach the
  # capture handler and the scan below would pass over it. The level is lowered
  # for this test and restored afterwards. This module is synchronous, and
  # ExUnit runs synchronous modules after the asynchronous ones, so no other
  # test is running while the level is down.
  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    Logger.put_module_level(Ecto.Adapters.SQL, :none)

    on_exit(fn ->
      Logger.delete_module_level(Ecto.Adapters.SQL)
      Logger.configure(level: previous)
    end)

    :ok
  end

  # The one function that returns a freshly minted plaintext credential, and
  # every module that calls it. Both discard it; neither renders it.
  @create_callers [OpenAgentsWeb.AssignmentController, OpenAgentsWeb.IssueShowLive]

  # The vault holds the plaintext between the mint and the `agent` frame.
  # Writing to it and reading from it are one module each.
  @vault_writers [OpenAgents.Forge.Assignments]
  @vault_readers [OpenAgents.Work.DelegationServer]

  # Tables whose rows are not application state and are not scanned.
  @unscanned_tables ["schema_migrations"]

  describe "who can hold a plaintext credential" do
    test "the modules that receive a minted credential are exactly the ones named" do
      assert_exact_set(
        callers_of([{Assignments, :create, 1}]),
        @create_callers,
        "receives a freshly minted assignment credential"
      )
    end

    test "the vault is written by one module and read by one module" do
      assert_exact_set(
        callers_of([{AssignmentCredentialVault, :put, 2}]),
        @vault_writers,
        "puts a plaintext credential into the vault"
      )

      assert_exact_set(
        callers_of([{AssignmentCredentialVault, :take, 1}]),
        @vault_readers,
        "takes a plaintext credential out of the vault"
      )
    end
  end

  describe "where a plaintext credential could land" do
    test "a delegation writes the credential to no table, no log line, and no response" do
      user = github_user("assignment-credential-reach")
      {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
      repository = repository_with_member_fixture(user)
      {:ok, issue} = Issues.create_issue(repository, %{title: "Credential reach"})
      machine = paired_machine(user, "credential-reach", ["codex"], true)
      test_process = self()

      start_supervised!(
        {FakeController,
         machine_id: machine.id,
         script: fn {:agent, request_id, payload, caller} ->
           send(test_process, {:assignment_request, request_id, payload, caller})
         end}
      )

      {{response, frame, request_id, caller}, log} =
        with_log(fn ->
          response =
            build_conn()
            |> put_api_token(user, ["computer:control"])
            |> post(
              ~p"/api/v1/conversations/#{conversation.id}/computers/#{machine.id}/assignments",
              %{
                "repository_id" => repository.id,
                "issue_number" => issue.number,
                "branch" => "agent/credential-reach-#{issue.number}",
                "agent_id" => "codex",
                "prompt" => "Implement the issue",
                "cwd" => @root
              }
            )
            |> json_response(202)

          assert_receive {:assignment_request, request_id, frame, caller}, 1_000
          {response, frame, request_id, caller}
        end)

      assignment_id = response["assignment"]["id"]
      credential = frame["assignment_credential"]
      assert is_binary(credential)
      assert String.starts_with?(credential, "oa_assignment_")

      # The frame delivers it once, under one key.
      assert keys_holding(frame, credential) == ["assignment_credential"], """
      The `agent` frame carries the plaintext credential under more than the one
      key IDENTITY-010 names.
      """

      refute inspect(response) =~ credential

      # The scanner works: a value that is persisted is found.
      assert tables_holding(assignment_id) != [], """
      The database scan found the assignment id in no table, so it is not
      reading rows and would report a leak as clean.
      """

      assert tables_holding(credential) == [], """
      The plaintext assignment credential is persisted while the delegation is
      running, in #{inspect(tables_holding(credential))}. IDENTITY-010 says it
      exists only in memory.
      """

      refute log =~ credential

      job =
        Repo.one!(
          from j in Work.Job,
            where: fragment("?->>'assignment_id'", j.delegation) == ^assignment_id
        )

      [{job_pid, _value}] = Horde.Registry.lookup(OpenAgents.HordeRegistry, {:work_job, job.id})
      reference = Process.monitor(job_pid)

      {_result, completion_log} =
        with_log(fn ->
          FakeController.exit(caller, request_id, %{"status" => "completed", "output" => "done"})
          assert_receive {:DOWN, ^reference, :process, ^job_pid, :normal}, 1_000
        end)

      refute completion_log =~ credential

      assert tables_holding(credential) == [], """
      The plaintext assignment credential is persisted once the delegation
      finishes, in #{inspect(tables_holding(credential))} — a report, a journal,
      an activity row, or a projection added since IDENTITY-010's list was
      written.
      """

      assignment = Repo.get!(OpenAgents.Forge.Assignment, assignment_id)
      assert assignment.state == "completed"
      assert Assignments.credential(assignment).revoked_at
      assert AssignmentCredentialVault.take(assignment_id) == nil
    end
  end

  # ── enumeration helpers ────────────────────────────────────────────────

  # Every base table PostgreSQL's own catalog knows about, so a table added
  # later is scanned without anyone adding it here.
  defp base_tables do
    %Postgrex.Result{rows: rows} =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name
      """)

    rows |> List.flatten() |> Enum.reject(&(&1 in @unscanned_tables))
  end

  # Casting a row to text renders every column of it, so a new column is
  # covered by the same query as the old ones.
  defp tables_holding(value) do
    Enum.filter(base_tables(), fn table ->
      statement =
        "SELECT count(*) FROM public.\"" <>
          table <> "\" AS scanned WHERE strpos(scanned::text, $1) > 0"

      %Postgrex.Result{rows: [[count]]} = Repo.query!(statement, [value])

      count > 0
    end)
  end

  defp keys_holding(map, value) when is_map(map) do
    for {key, item} <- map, is_binary(item), String.contains?(item, value), do: key
  end

  # Read from each compiled module's import table rather than from source text.
  defp callers_of(mfas) do
    wanted = MapSet.new(mfas)
    {:ok, modules} = :application.get_key(:openagents, :modules)

    Enum.filter(modules, fn module ->
      with path when is_list(path) <- :code.which(module),
           {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
        Enum.any?(imports, &MapSet.member?(wanted, &1))
      else
        _unreadable -> false
      end
    end)
  end

  defp assert_exact_set(actual, declared, what) do
    actual = MapSet.new(actual)
    declared = MapSet.new(declared)

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           Something that #{what} is not named in
           test/openagents/forge/assignment_credential_reach_test.exs. Amend
           IDENTITY-010 in INVARIANTS.md, then add it here.

           Undeclared: #{inspect(MapSet.difference(actual, declared) |> MapSet.to_list())}
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           This test names something that no longer #{what}. Amend IDENTITY-010
           in INVARIANTS.md, then remove it here.

           Stale: #{inspect(MapSet.difference(declared, actual) |> MapSet.to_list())}
           """
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp paired_machine(user, name, agent_ids, scoped_forge_credentials_enabled) do
    assert {:ok, pairing} =
             Machines.start_pairing(%{
               "name" => name,
               "tier" => "curated",
               "platform" => "linux-x64",
               "agent_version" => "0.4.0",
               "roots" => [@root]
             })

    assert {:ok, machine} =
             Machines.approve_pairing(user, pairing.code,
               scoped_forge_credentials_enabled: scoped_forge_credentials_enabled
             )

    assert {:ok, machine} =
             Machines.store_probe(machine, %{
               "acp_agents" => Enum.map(agent_ids, &%{"id" => &1, "version" => "1.0"})
             })

    machine
  end

  defp put_api_token(conn, user, scopes) do
    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{
        name: "Assignment credential reach test",
        scopes: scopes,
        lifetime_days: 1
      })

    put_req_header(conn, "authorization", "Bearer " <> plaintext)
  end
end
