defmodule OpenAgentsWeb.StackControllerTest do
  use OpenAgentsWeb.ConnCase

  alias OpenAgents.Forge.Repos
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks.IdempotencyRequest
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEvent

  import Ecto.Query
  import OpenAgents.IssuesFixtures

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "stack-controller-#{System.unique_integer([:positive])}"
      )

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    :ok
  end

  describe "POST /api/v1/repos/:owner/:repo/stacks" do
    test "creates a stack, reads it back, and replays the idempotency key", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2", "layer-3"])
      [pr_1, pr_2, pr_3] = pull_request_chain(repository, oids, ["layer-1", "layer-2", "layer-3"])
      conn = put_forge_api_token(conn, "stack-create", repository)

      body = %{
        trunk_ref: "main",
        pull_requests: [pr_1, pr_2, pr_3],
        expected_heads: %{
          "#{pr_1}" => oids["layer-1"],
          "#{pr_2}" => oids["layer-2"],
          "#{pr_3}" => oids["layer-3"]
        }
      }

      create_conn =
        conn
        |> put_req_header("idempotency-key", "stack-create-1")
        |> post(path(repository), body)

      assert %{
               "number" => 1,
               "trunk_ref" => "main",
               "state" => "open",
               "health" => "healthy",
               "version" => 1,
               "size" => 3,
               "replayed" => false,
               "entries" => [entry_1, entry_2, entry_3]
             } = json_response(create_conn, 201)

      assert %{"position" => 1, "boundary_oid" => boundary_1} = entry_1
      assert boundary_1 == oids["main"]
      assert %{"position" => 2, "boundary_oid" => boundary_2} = entry_2
      assert boundary_2 == oids["layer-1"]
      assert %{"position" => 3, "observed_head_oid" => head_3} = entry_3
      assert head_3 == oids["layer-3"]

      events = Repo.all(from event in StackEvent, order_by: [asc: event.inserted_at])

      assert [%StackEvent{event_type: "pull_request_stack.created", stack_version: 1} | stacked] =
               events

      assert Enum.map(stacked, & &1.event_type) == List.duplicate("pull_request.stacked", 3)

      replay_conn =
        conn
        |> put_req_header("idempotency-key", "stack-create-1")
        |> post(path(repository), body)

      assert %{"number" => 1, "replayed" => true} = json_response(replay_conn, 201)
      assert Repo.aggregate(Stack, :count) == 1
      assert Repo.aggregate(IdempotencyRequest, :count) == 1

      show_conn = get(conn, "#{path(repository)}/1")
      assert %{"number" => 1, "size" => 3} = json_response(show_conn, 200)

      index_conn = get(conn, path(repository))
      assert [%{"number" => 1}] = json_response(index_conn, 200)
    end

    test "rejects a reused idempotency key with a different request", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-idem-conflict", repository)

      first =
        conn
        |> put_req_header("idempotency-key", "stack-idem-1")
        |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})

      assert %{"number" => 1} = json_response(first, 201)

      second =
        conn
        |> put_req_header("idempotency-key", "stack-idem-1")
        |> post(path(repository), %{trunk_ref: "other", pull_requests: [pr_1]})

      assert %{"code" => "idempotency_conflict"} = json_response(second, 409)
    end

    test "requires one Idempotency-Key header", %{conn: conn} do
      repository = repository_fixture()
      conn = put_forge_api_token(conn, "stack-no-key", repository)

      conn = post(conn, path(repository), %{trunk_ref: "main", pull_requests: [1]})
      assert %{"message" => "Provide one Idempotency-Key header"} = json_response(conn, 400)
    end

    test "refuses a caller without write access", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-nonmember")

      conn =
        conn
        |> put_req_header("idempotency-key", "stack-forbidden-1")
        |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})

      assert json_response(conn, 403)
    end

    test "rejects each structural violation with an explanation", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2", "layer-3"])
      [pr_1, pr_2, pr_3] = pull_request_chain(repository, oids, ["layer-1", "layer-2", "layer-3"])
      conn = put_forge_api_token(conn, "stack-rejections", repository)

      post_stack = fn body, key ->
        conn
        |> put_req_header("idempotency-key", key)
        |> post(path(repository), body)
      end

      response = post_stack.(%{trunk_ref: "main"}, "reject-1")
      assert %{"code" => "invalid_request"} = json_response(response, 422)

      response = post_stack.(%{trunk_ref: "main", pull_requests: [999]}, "reject-2")
      assert json_response(response, 404)

      response =
        post_stack.(%{trunk_ref: "wrong-trunk", pull_requests: [pr_1, pr_2]}, "reject-3")

      assert %{"code" => "trunk_mismatch"} = json_response(response, 422)

      response = post_stack.(%{trunk_ref: "main", pull_requests: [pr_1, pr_3]}, "reject-4")
      assert %{"code" => "broken_base_chain"} = json_response(response, 422)

      response = post_stack.(%{trunk_ref: "main", pull_requests: [pr_1, pr_1]}, "reject-5")
      assert %{"code" => "duplicate_pull_request"} = json_response(response, 422)

      response =
        post_stack.(
          %{
            trunk_ref: "main",
            pull_requests: [pr_1],
            expected_heads: %{"#{pr_1}" => String.duplicate("a", 40)}
          },
          "reject-6"
        )

      assert %{"code" => "expected_head_mismatch"} = json_response(response, 409)

      closed = pull_request(repository, "orphan", "main", oids["main"], oids["main"], "closed")

      response = post_stack.(%{trunk_ref: "main", pull_requests: [closed]}, "reject-7")
      assert %{"code" => "pull_request_not_open"} = json_response(response, 422)

      assert %{"number" => 1} =
               post_stack.(%{trunk_ref: "main", pull_requests: [pr_1, pr_2]}, "accept-1")
               |> json_response(201)

      response = post_stack.(%{trunk_ref: "main", pull_requests: [pr_1]}, "reject-8")
      assert %{"code" => "already_stacked"} = json_response(response, 422)
    end

    test "records the fork point as the boundary when the trunk moved past the branch", %{
      conn: conn
    } do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-fork-point", repository)

      # The trunk advances after the branch forked, so the boundary must be
      # the fork point — recording the moved tip would make a later merge
      # land a tree that reverts the advance commit.
      git_dir = Repos.ensure_repo!(repository.storage_key, repository.default_branch)
      {trunk_tip, _tree} = commit(git_dir, oids["main"], "Trunk advance", "trunk.md")
      {_, 0} = Repos.git(git_dir, ["update-ref", "refs/heads/main", trunk_tip])

      create_conn =
        conn
        |> put_req_header("idempotency-key", "stack-fork-point-1")
        |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})

      assert %{"entries" => [entry]} = json_response(create_conn, 201)
      assert entry["boundary_oid"] == oids["main"]
    end

    test "rejects a head ref the git service cannot resolve", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, [])
      missing = pull_request(repository, "ghost", "main", oids["main"], oids["main"], "open")
      conn = put_forge_api_token(conn, "stack-missing-ref", repository)

      conn =
        conn
        |> put_req_header("idempotency-key", "stack-missing-1")
        |> post(path(repository), %{trunk_ref: "main", pull_requests: [missing]})

      assert %{"code" => "invalid_ref"} = json_response(conn, 422)
    end
  end

  describe "POST /api/v1/repos/:owner/:repo/stacks/:stack_number/append" do
    test "appends to the top, bumps the version, and replays retries", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      pr_2 = pull_request(repository, "layer-2", "layer-1", oids["layer-1"], oids["layer-2"])
      conn = put_forge_api_token(conn, "stack-append", repository)

      assert %{"number" => 1, "version" => 1} =
               conn
               |> put_req_header("idempotency-key", "append-create-1")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      append_conn =
        conn
        |> put_req_header("idempotency-key", "append-1")
        |> post("#{path(repository)}/1/append", %{
          pull_request: pr_2,
          expected_stack_version: 1,
          expected_head: oids["layer-2"]
        })

      assert %{
               "version" => 2,
               "size" => 2,
               "replayed" => false,
               "entries" => [_bottom, %{"position" => 2, "boundary_oid" => boundary}]
             } = json_response(append_conn, 200)

      assert boundary == oids["layer-1"]

      assert Repo.exists?(
               from event in StackEvent,
                 where: event.event_type == "pull_request_stack.appended"
             )

      replay_conn =
        conn
        |> put_req_header("idempotency-key", "append-1")
        |> post("#{path(repository)}/1/append", %{
          pull_request: pr_2,
          expected_stack_version: 1,
          expected_head: oids["layer-2"]
        })

      assert %{"version" => 2, "replayed" => true} = json_response(replay_conn, 200)
      assert Repo.aggregate(Stack, :count) == 1
    end

    test "rejects a stale expected version, a non-top target, and a missing stack", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      pr_2 = pull_request(repository, "layer-2", "layer-1", oids["layer-1"], oids["layer-2"])
      orphan = pull_request(repository, "orphan", "main", oids["main"], oids["main"], "open")
      conn = put_forge_api_token(conn, "stack-append-reject", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "append-reject-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      stale =
        conn
        |> put_req_header("idempotency-key", "append-reject-1")
        |> post("#{path(repository)}/1/append", %{pull_request: pr_2, expected_stack_version: 9})

      assert %{"code" => "stale_stack_version"} = json_response(stale, 409)

      not_top =
        conn
        |> put_req_header("idempotency-key", "append-reject-2")
        |> post("#{path(repository)}/1/append", %{pull_request: orphan})

      assert %{"code" => "not_stack_top"} = json_response(not_top, 422)

      missing =
        conn
        |> put_req_header("idempotency-key", "append-reject-3")
        |> post("#{path(repository)}/9/append", %{pull_request: pr_2})

      assert json_response(missing, 404)
    end

    test "refuses to extend a stack that is no longer open", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      pr_2 = pull_request(repository, "layer-2", "layer-1", oids["layer-1"], oids["layer-2"])
      conn = put_forge_api_token(conn, "stack-append-closed", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "append-closed-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      {:ok, _stack} =
        OpenAgents.Stacks.dissolve(Repo.get_by!(Stack, repository_id: repository.id))

      conn =
        conn
        |> put_req_header("idempotency-key", "append-closed-1")
        |> post("#{path(repository)}/1/append", %{pull_request: pr_2})

      assert %{"code" => "stack_not_open"} = json_response(conn, 409)
    end
  end

  describe "POST /api/v1/repos/:owner/:repo/stacks/:stack_number/unstack" do
    test "removes the top layer, records the event, and replays retries", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1, pr_2] = pull_request_chain(repository, oids, ["layer-1", "layer-2"])
      conn = put_forge_api_token(conn, "stack-unstack", repository)

      assert %{"number" => 1, "version" => 1} =
               conn
               |> put_req_header("idempotency-key", "unstack-create-1")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1, pr_2]})
               |> json_response(201)

      unstack_conn =
        conn
        |> put_req_header("idempotency-key", "unstack-1")
        |> post("#{path(repository)}/1/unstack", %{
          pull_request: pr_2,
          expected_stack_version: 1
        })

      assert %{
               "state" => "open",
               "version" => 2,
               "size" => 1,
               "replayed" => false,
               "entries" => [%{"position" => 1}]
             } = json_response(unstack_conn, 200)

      assert Repo.exists?(
               from event in StackEvent,
                 where:
                   event.event_type == "pull_request.unstacked" and
                     fragment("?->>'reason' = 'unstacked'", event.payload)
             )

      replay_conn =
        conn
        |> put_req_header("idempotency-key", "unstack-1")
        |> post("#{path(repository)}/1/unstack", %{
          pull_request: pr_2,
          expected_stack_version: 1
        })

      assert %{"size" => 1, "replayed" => true} = json_response(replay_conn, 200)
    end

    test "dissolves the stack when the last layer leaves", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-unstack-last", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "unstack-last-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      unstack_conn =
        conn
        |> put_req_header("idempotency-key", "unstack-last-1")
        |> post("#{path(repository)}/1/unstack", %{pull_request: pr_1})

      assert %{"state" => "dissolved", "size" => 0, "entries" => []} =
               json_response(unstack_conn, 200)

      assert Repo.exists?(
               from event in StackEvent,
                 where: event.event_type == "pull_request_stack.dissolved"
             )
    end

    test "rejects a non-top layer and an unknown pull request", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1, _pr_2] = pull_request_chain(repository, oids, ["layer-1", "layer-2"])
      conn = put_forge_api_token(conn, "stack-unstack-reject", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "unstack-reject-create")
               |> post(path(repository), %{
                 trunk_ref: "main",
                 pull_requests: [pr_1, pr_1 + 1]
               })
               |> json_response(201)

      not_top =
        conn
        |> put_req_header("idempotency-key", "unstack-reject-1")
        |> post("#{path(repository)}/1/unstack", %{pull_request: pr_1})

      assert %{"code" => "not_stack_top"} = json_response(not_top, 422)

      unknown =
        conn
        |> put_req_header("idempotency-key", "unstack-reject-2")
        |> post("#{path(repository)}/1/unstack", %{pull_request: 999})

      assert %{"code" => "pull_request_not_in_stack"} = json_response(unknown, 422)
    end
  end

  describe "POST /api/v1/repos/:owner/:repo/stacks/:stack_number/dissolve" do
    test "releases every layer, dissolves the stack, and replays retries", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1, pr_2] = pull_request_chain(repository, oids, ["layer-1", "layer-2"])
      conn = put_forge_api_token(conn, "stack-dissolve", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "dissolve-create-1")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1, pr_2]})
               |> json_response(201)

      dissolve_conn =
        conn
        |> put_req_header("idempotency-key", "dissolve-1")
        |> post("#{path(repository)}/1/dissolve", %{expected_stack_version: 1})

      assert %{"state" => "dissolved", "size" => 0, "entries" => [], "replayed" => false} =
               json_response(dissolve_conn, 200)

      unstacked =
        Repo.all(
          from event in StackEvent,
            where:
              event.event_type == "pull_request.unstacked" and
                fragment("?->>'reason' = 'dissolved'", event.payload)
        )

      assert length(unstacked) == 2

      assert Repo.exists?(
               from event in StackEvent,
                 where: event.event_type == "pull_request_stack.dissolved"
             )

      replay_conn =
        conn
        |> put_req_header("idempotency-key", "dissolve-1")
        |> post("#{path(repository)}/1/dissolve", %{expected_stack_version: 1})

      assert %{"state" => "dissolved", "replayed" => true} = json_response(replay_conn, 200)

      again =
        conn
        |> put_req_header("idempotency-key", "dissolve-2")
        |> post("#{path(repository)}/1/dissolve", %{})

      assert %{"code" => "stack_not_open"} = json_response(again, 409)
    end

    test "refuses while an operation is active", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-dissolve-active", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "dissolve-active-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      assert %{"id" => operation_id} =
               conn
               |> put_req_header("idempotency-key", "dissolve-active-rebase")
               |> post("#{path(repository)}/1/rebase", %{})
               |> json_response(202)

      blocked =
        conn
        |> put_req_header("idempotency-key", "dissolve-active-1")
        |> post("#{path(repository)}/1/dissolve", %{})

      assert %{"code" => "operation_in_progress", "operation_id" => ^operation_id} =
               json_response(blocked, 409)
    end
  end

  describe "POST /api/v1/repos/:owner/:repo/stacks/:stack_number/rebase" do
    test "accepts a rebase, exposes the operation, and replays retries", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-rebase", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "rebase-create-1")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      rebase_conn =
        conn
        |> put_req_header("idempotency-key", "rebase-1")
        |> post("#{path(repository)}/1/rebase", %{})

      assert %{
               "id" => operation_id,
               "kind" => "rebase",
               "state" => "pending",
               "replayed" => false
             } = json_response(rebase_conn, 202)

      assert %{"health" => "operation_in_progress"} =
               json_response(get(conn, "#{path(repository)}/1"), 200)

      replay_conn =
        conn
        |> put_req_header("idempotency-key", "rebase-1")
        |> post("#{path(repository)}/1/rebase", %{})

      assert %{"id" => ^operation_id, "replayed" => true} = json_response(replay_conn, 202)

      second_conn =
        conn
        |> put_req_header("idempotency-key", "rebase-2")
        |> post("#{path(repository)}/1/rebase", %{})

      assert %{"code" => "operation_in_progress"} = json_response(second_conn, 409)

      show_conn = get(conn, "#{path(repository)}/1/operations/#{operation_id}")
      assert %{"id" => ^operation_id, "state" => "pending"} = json_response(show_conn, 200)

      missing_conn =
        get(conn, "#{path(repository)}/1/operations/00000000-0000-0000-0000-000000000000")

      assert json_response(missing_conn, 404)
    end

    test "continue requires a paused operation, and abort cancels", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-rebase-ops", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "rebase-ops-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      assert %{"id" => operation_id} =
               conn
               |> put_req_header("idempotency-key", "rebase-ops-1")
               |> post("#{path(repository)}/1/rebase", %{})
               |> json_response(202)

      continue_conn =
        post(conn, "#{path(repository)}/1/operations/#{operation_id}/continue", %{
          resolution_oid: oids["layer-1"]
        })

      assert %{"code" => "operation_not_waiting"} = json_response(continue_conn, 409)

      abort_conn = post(conn, "#{path(repository)}/1/operations/#{operation_id}/abort", %{})
      assert %{"id" => ^operation_id, "state" => "cancelled"} = json_response(abort_conn, 200)

      assert %{"health" => "healthy"} = json_response(get(conn, "#{path(repository)}/1"), 200)

      again_conn = post(conn, "#{path(repository)}/1/operations/#{operation_id}/abort", %{})
      assert %{"code" => "operation_not_abortable"} = json_response(again_conn, 409)
    end

    test "refuses a caller without write access", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [_pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-rebase-outsider")

      conn =
        conn
        |> put_req_header("idempotency-key", "rebase-forbidden-1")
        |> post("#{path(repository)}/1/rebase", %{})

      assert json_response(conn, 403)
    end
  end

  describe "POST /api/v1/repos/:owner/:repo/stacks/:stack_number/merge" do
    test "accepts a merge, exposes the operation, and replays retries", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-merge", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "merge-create-1")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      body = %{pull_request_number: pr_1, merge_method: "merge"}

      merge_conn =
        conn
        |> put_req_header("idempotency-key", "merge-1")
        |> post("#{path(repository)}/1/merge", body)

      assert %{
               "id" => operation_id,
               "kind" => "merge",
               "state" => "pending",
               "replayed" => false
             } = json_response(merge_conn, 202)

      assert %{"health" => "operation_in_progress"} =
               json_response(get(conn, "#{path(repository)}/1"), 200)

      replay_conn =
        conn
        |> put_req_header("idempotency-key", "merge-1")
        |> post("#{path(repository)}/1/merge", body)

      assert %{"id" => ^operation_id, "replayed" => true} = json_response(replay_conn, 202)

      show_conn = get(conn, "#{path(repository)}/1/operations/#{operation_id}")
      assert %{"id" => ^operation_id, "state" => "pending"} = json_response(show_conn, 200)
    end

    test "rejects a queue action, a stranger PR, and a bad method", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-merge-invalid", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "merge-invalid-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      queue_conn =
        conn
        |> put_req_header("idempotency-key", "merge-queue-1")
        |> post("#{path(repository)}/1/merge", %{
          pull_request_number: pr_1,
          merge_method: "merge",
          merge_action: "queue"
        })

      assert %{"code" => "merge_queue_unavailable"} = json_response(queue_conn, 409)

      stranger_conn =
        conn
        |> put_req_header("idempotency-key", "merge-stranger-1")
        |> post("#{path(repository)}/1/merge", %{
          pull_request_number: 999_999,
          merge_method: "merge"
        })

      assert %{"code" => "pull_request_not_in_stack"} = json_response(stranger_conn, 422)

      method_conn =
        conn
        |> put_req_header("idempotency-key", "merge-method-1")
        |> post("#{path(repository)}/1/merge", %{
          pull_request_number: pr_1,
          merge_method: "octopus"
        })

      assert %{"code" => "invalid_request"} = json_response(method_conn, 422)
    end

    test "refuses a caller without write access", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "stack-merge-outsider")

      conn =
        conn
        |> put_req_header("idempotency-key", "merge-forbidden-1")
        |> post("#{path(repository)}/1/merge", %{
          pull_request_number: pr_1,
          merge_method: "merge"
        })

      assert json_response(conn, 403)
    end
  end

  describe "PUT /api/v1/repos/:owner/:repo/pulls/:pull_number/merge-async" do
    test "accepts a submission, polls it, replays retries, and reports the active conflict",
         %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1, pr_2] = pull_request_chain(repository, oids, ["layer-1", "layer-2"])
      conn = put_forge_api_token(conn, "merge-async", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "merge-async-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1, pr_2]})
               |> json_response(201)

      submit_conn =
        conn
        |> put_req_header("idempotency-key", "merge-async-1")
        |> put("#{pulls_path(repository)}/#{pr_1}/merge-async", %{})

      assert %{
               "operation_id" => operation_id,
               "merge_status" => "pending",
               "state" => "pending",
               "merge_method" => "merge",
               "pull_request" => ^pr_1,
               "replayed" => false,
               "url" => poll_url
             } = json_response(submit_conn, 202)

      assert String.ends_with?(
               poll_url,
               "#{pulls_path(repository)}/#{pr_1}/merge-async/#{operation_id}"
             )

      poll_conn = get(conn, "#{pulls_path(repository)}/#{pr_1}/merge-async/#{operation_id}")

      assert %{"operation_id" => ^operation_id, "merge_status" => "pending"} =
               json_response(poll_conn, 200)

      replay_conn =
        conn
        |> put_req_header("idempotency-key", "merge-async-1")
        |> put("#{pulls_path(repository)}/#{pr_1}/merge-async", %{})

      assert %{"operation_id" => ^operation_id, "replayed" => true} =
               json_response(replay_conn, 202)

      second_conn =
        conn
        |> put_req_header("idempotency-key", "merge-async-2")
        |> put("#{pulls_path(repository)}/#{pr_2}/merge-async", %{})

      assert %{"code" => "operation_in_progress", "operation_id" => ^operation_id} =
               json_response(second_conn, 409)
    end

    test "scopes the poll to the submitting pull request", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1, pr_2] = pull_request_chain(repository, oids, ["layer-1", "layer-2"])
      conn = put_forge_api_token(conn, "merge-async-scope", repository)

      assert %{"number" => 1} =
               conn
               |> put_req_header("idempotency-key", "merge-async-scope-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1, pr_2]})
               |> json_response(201)

      assert %{"operation_id" => operation_id} =
               conn
               |> put_req_header("idempotency-key", "merge-async-scope-1")
               |> put("#{pulls_path(repository)}/#{pr_1}/merge-async", %{})
               |> json_response(202)

      other_conn = get(conn, "#{pulls_path(repository)}/#{pr_2}/merge-async/#{operation_id}")
      assert json_response(other_conn, 404)

      bogus_conn = get(conn, "#{pulls_path(repository)}/#{pr_1}/merge-async/not-a-uuid")
      assert json_response(bogus_conn, 404)
    end

    test "rejects an unstacked pull request and an unknown pull request", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      solo = pull_request(repository, "layer-1", "main", oids["main"], oids["layer-1"])
      conn = put_forge_api_token(conn, "merge-async-unstacked", repository)

      solo_conn =
        conn
        |> put_req_header("idempotency-key", "merge-async-solo-1")
        |> put("#{pulls_path(repository)}/#{solo}/merge-async", %{})

      assert %{"code" => "not_stacked"} = json_response(solo_conn, 422)

      missing_conn =
        conn
        |> put_req_header("idempotency-key", "merge-async-missing-1")
        |> put("#{pulls_path(repository)}/999999/merge-async", %{})

      assert json_response(missing_conn, 404)
    end

    test "refuses a caller without write access", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1"])
      [pr_1] = pull_request_chain(repository, oids, ["layer-1"])
      conn = put_forge_api_token(conn, "merge-async-outsider")

      writer_conn =
        Phoenix.ConnTest.build_conn()
        |> put_forge_api_token("merge-async-owner", repository)

      assert %{"number" => 1} =
               writer_conn
               |> put_req_header("idempotency-key", "merge-async-outsider-create")
               |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1]})
               |> json_response(201)

      conn =
        conn
        |> put_req_header("idempotency-key", "merge-async-outsider-1")
        |> put("#{pulls_path(repository)}/#{pr_1}/merge-async", %{})

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/repos/:owner/:repo/stacks" do
    test "reads are public for a public repository", %{conn: conn} do
      repository = repository_fixture()

      assert [] == json_response(get(conn, path(repository)), 200)
      assert json_response(get(conn, "#{path(repository)}/1"), 404)
    end
  end

  describe "stack membership in pull request payloads" do
    test "stacked pull requests embed the stack context; unstacked carry nil", %{conn: conn} do
      repository = repository_fixture()
      oids = seed_chain(repository, ["layer-1", "layer-2"])
      [pr_1, pr_2] = pull_request_chain(repository, oids, ["layer-1", "layer-2"])
      solo = pull_request(repository, "layer-2", "main", oids["main"], oids["layer-2"])
      conn = put_forge_api_token(conn, "stack-payload", repository)

      create_conn =
        conn
        |> put_req_header("idempotency-key", "stack-payload-1")
        |> post(path(repository), %{trunk_ref: "main", pull_requests: [pr_1, pr_2]})

      assert %{"number" => stack_number} = json_response(create_conn, 201)

      pulls = "/api/v1/repos/#{repository.owner}/#{repository.name}/pulls"

      show_conn = get(conn, "#{pulls}/#{pr_2}")
      main_oid = oids["main"]

      assert %{
               "stack" => %{
                 "number" => ^stack_number,
                 "position" => 2,
                 "size" => 2,
                 "health" => "healthy",
                 "base" => %{"ref" => "main", "sha" => ^main_oid}
               }
             } = json_response(show_conn, 200)

      solo_conn = get(conn, "#{pulls}/#{solo}")
      assert %{"stack" => nil} = json_response(solo_conn, 200)

      index_conn = get(conn, pulls)
      by_number = Map.new(json_response(index_conn, 200), &{&1["number"], &1})
      assert %{"stack" => %{"position" => 1, "size" => 2}} = Map.fetch!(by_number, pr_1)
      assert %{"stack" => nil} = Map.fetch!(by_number, solo)
    end
  end

  defp path(repository), do: "/api/v1/repos/#{repository.owner}/#{repository.name}/stacks"

  defp pulls_path(repository),
    do: "/api/v1/repos/#{repository.owner}/#{repository.name}/pulls"

  defp seed_chain(repository, branches) do
    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)

    {main, _tree} = commit(path, nil, "Seed repository", "README.md")
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", main])

    branches
    |> Enum.with_index(1)
    |> Enum.reduce(%{"main" => main}, fn {branch, index}, oids ->
      parent = Map.fetch!(oids, Enum.at(["main" | branches], index - 1))
      {oid, _tree} = commit(path, parent, "Layer #{branch}", "#{branch}.md")
      {_, 0} = Repos.git(path, ["update-ref", "refs/heads/#{branch}", oid])
      Map.put(oids, branch, oid)
    end)
  end

  defp commit(path, parent, message, file) do
    blob = git!(path, ["hash-object", "-w", "--stdin"], "#{file}\n")
    tree = git!(path, ["mktree"], "100644 blob #{blob}\t#{file}\n")
    parent_args = if parent, do: ["-p", parent], else: []

    oid =
      git!(path, ["commit-tree", tree] ++ parent_args ++ ["-m", message], "",
        env: [
          {"GIT_AUTHOR_NAME", "Test Author"},
          {"GIT_AUTHOR_EMAIL", "author@example.test"},
          {"GIT_COMMITTER_NAME", "Test Author"},
          {"GIT_COMMITTER_EMAIL", "author@example.test"}
        ]
      )

    {oid, tree}
  end

  defp pull_request_chain(repository, oids, branches) do
    branches
    |> Enum.with_index()
    |> Enum.map(fn {branch, index} ->
      base = Enum.at(["main" | branches], index)
      pull_request(repository, branch, base, oids[base], oids[branch])
    end)
  end

  defp pull_request(repository, head_ref, base_ref, base_sha, head_sha, state \\ "open") do
    issue = issue_fixture(repository, %{title: "PR #{head_ref}"})

    {:ok, _pull_request} =
      %PullRequest{}
      |> PullRequest.changeset(%{
        repository_id: repository.id,
        issue_id: issue.id,
        head_repository_id: repository.id,
        head_ref: head_ref,
        head_sha: head_sha,
        base_ref: base_ref,
        base_sha: base_sha,
        state: state
      })
      |> Repo.insert()

    issue.number
  end

  defp git!(git_dir, args, input, options \\ []) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "stack-controller-input-#{System.unique_integer([:positive])}"
      )

    File.write!(input_path, input)

    try do
      {output, 0} =
        System.cmd(
          "sh",
          ["-c", ~s(exec git --git-dir "$GIT_DIR" "$@" < "$INPUT"), "sh"] ++ args,
          env: [{"GIT_DIR", git_dir}, {"INPUT", input_path}] ++ Keyword.get(options, :env, [])
        )

      String.trim(output)
    after
      File.rm(input_path)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
