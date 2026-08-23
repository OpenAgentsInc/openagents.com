defmodule OpenAgents.Tools.OpenPullRequestTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Chat.OpenRouter
  alias OpenAgents.Forge.WAL
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repositories.RepositoryPublication
  alias OpenAgents.Tools.{ExecutionContext, OpenPullRequest, Registry, Runner}

  setup do
    wal_dir =
      Path.join(System.tmp_dir!(), "open-pull-request-wal-#{System.unique_integer([:positive])}")

    previous_wal_dir = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_wal_dir, wal_dir)

    user = repository_user_fixture("pull-request-tool-owner")
    repository = repository_with_member_fixture(user)
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)
    owner = OpenAgents.Conversations.get_conversation_owner!(conversation)
    conversation_id = Ecto.UUID.generate()
    workspace_ref = "workspace:#{Ecto.UUID.generate()}"
    branch = "openagents/chat/#{conversation_id}"
    base_oid = String.duplicate("a", 40)
    head_oid = String.duplicate("b", 40)

    write_wal(repository.storage_key, [
      %{"refs/heads/main" => base_oid, "refs/heads/#{branch}" => head_oid}
    ])

    publication =
      publication_fixture(repository, user, conversation_id, workspace_ref, branch, head_oid, 0)

    context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{conversation_id}",
      authorities: MapSet.new(["pull_request.write"]),
      surface: "text",
      owner_user_id: user.id,
      owner_visitor_id: owner.id,
      conversation_id: conversation_id,
      workspace: %{
        "type" => "repository_workspace",
        "repository_id" => repository.id,
        "workspace_ref" => workspace_ref
      }
    }

    on_exit(fn ->
      if previous_wal_dir,
        do: Application.put_env(:openagents, :forge_wal_dir, previous_wal_dir),
        else: Application.delete_env(:openagents, :forge_wal_dir)

      File.rm_rf!(wal_dir)
    end)

    %{
      branch: branch,
      context: context,
      head_oid: head_oid,
      publication: publication,
      repository: repository,
      user: user
    }
  end

  test "requires a separate exact approval and opens one draft pull request", %{context: context} do
    {:ok, snapshot} = Registry.build([OpenPullRequest])
    call = call("open-1", context)

    assert {:ok, refused} = Runner.run(snapshot, call, context)
    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "module_approval_required"

    publication_approval = %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "external_confirmation",
      "module_id" => "openagents.tool.publish_changes.v1",
      "version" => 1,
      "scope_ref" => context.scope_ref,
      "explicit" => true,
      "actor_type" => "person",
      "receipt_ref" => "approval:publication"
    }

    assert {:ok, still_refused} =
             Runner.run(snapshot, call, %{context | approval_receipts: [publication_approval]})

    assert still_refused["error"]["code"] == "module_approval_required"

    context = approve(context)
    assert {:ok, opened} = Runner.run(snapshot, call, context)
    assert opened["status"] == "succeeded"
    assert opened["result"]["state"] == "open"
    assert opened["result"]["draft"]
    assert opened["result"]["head"]["ref"] =~ "openagents/chat/"
    assert opened["result"]["repository"]
    assert opened["result"]["url"] =~ "/pulls/"
    assert opened["result"]["checks"]["state"] == "unknown"
    assert length(Repo.all(PullRequest)) == 1

    stored = Repo.one!(PullRequest) |> Repo.preload(:issue)
    assert stored.issue.body =~ "## OpenAgents publication"
    assert stored.issue.body =~ "Changed files: 2"
    assert stored.issue.body =~ "repository-publication:"
    assert stored.issue.body =~ "/compare/main...openagents/chat/"

    retry_call = %{call | call_id: "open-2"}
    assert {:ok, retried} = Runner.run(snapshot, retry_call, context)
    assert retried["result"]["id"] == opened["result"]["id"]
    assert length(Repo.all(PullRequest)) == 1
  end

  test "refreshes the existing open pull request from a later exact WAL publication", %{
    branch: branch,
    context: context,
    publication: publication,
    repository: repository,
    user: user
  } do
    {:ok, snapshot} = Registry.build([OpenPullRequest])
    context = approve(context)
    assert {:ok, first} = Runner.run(snapshot, call("open-first", context), context)

    next_oid = String.duplicate("c", 40)
    base_oid = String.duplicate("a", 40)

    write_wal(repository.storage_key, [
      %{"refs/heads/main" => base_oid, "refs/heads/#{branch}" => publication.published_oid},
      %{"refs/heads/main" => base_oid, "refs/heads/#{branch}" => next_oid}
    ])

    later =
      publication_fixture(
        repository,
        user,
        context.conversation_id,
        publication.workspace_ref,
        branch,
        next_oid,
        1
      )

    second_call =
      call("open-later", context, later)
      |> put_in(
        [:raw_arguments],
        Jason.encode!(%{
          "publication_receipt_ref" => "repository-publication:#{later.id}",
          "title" => "Updated pull request",
          "body" => "Updated body",
          "draft" => false
        })
      )

    assert {:ok, refreshed} = Runner.run(snapshot, second_call, context)
    assert refreshed["result"]["id"] == first["result"]["id"]
    assert refreshed["result"]["head"]["oid"] == next_oid
    refute refreshed["result"]["draft"]

    stored = Repo.one!(PullRequest) |> Repo.preload(:issue)
    assert stored.head_sha == next_oid
    assert stored.repository_publication_id == later.id
    assert stored.issue.title == "Updated pull request"
    assert stored.issue.body =~ "repository-publication:#{publication.id}"
    assert stored.issue.body =~ "repository-publication:#{later.id}"
  end

  test "refuses a publication branch that only shares the chat prefix", %{
    context: context,
    publication: publication
  } do
    invalid_branch = "#{publication.branch}/extra"

    publication
    |> Ecto.Changeset.change(branch: invalid_branch)
    |> Repo.update!()

    {:ok, snapshot} = Registry.build([OpenPullRequest])
    context = approve(context)

    assert {:ok, refused} = Runner.run(snapshot, call("open-invalid-branch", context), context)
    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "publication_branch_refused"
  end

  test "refuses another account, conversation, or workspace", %{
    context: context
  } do
    {:ok, snapshot} = Registry.build([OpenPullRequest])
    call = call("open-wrong-scope", context)

    another_user = repository_user_fixture("pull-request-tool-other-account")

    wrong_account =
      context
      |> Map.put(:owner_user_id, another_user.id)
      |> approve()

    assert {:ok, account_refused} = Runner.run(snapshot, call, wrong_account)
    assert account_refused["status"] == "refused"
    assert account_refused["error"]["code"] == "publication_scope_mismatch"

    conversation_id = Ecto.UUID.generate()

    wrong_conversation =
      context
      |> Map.put(:conversation_id, conversation_id)
      |> Map.put(:scope_ref, "conversation:#{conversation_id}")
      |> approve()

    assert {:ok, conversation_refused} = Runner.run(snapshot, call, wrong_conversation)
    assert conversation_refused["status"] == "refused"
    assert conversation_refused["error"]["code"] == "publication_scope_mismatch"

    wrong_workspace =
      context
      |> put_in([Access.key(:workspace), "workspace_ref"], "workspace:other")
      |> approve()

    assert {:ok, workspace_refused} = Runner.run(snapshot, call, wrong_workspace)
    assert workspace_refused["status"] == "refused"
    assert workspace_refused["error"]["code"] == "publication_workspace_mismatch"
  end

  test "refuses disabled policy and stale WAL receipts", %{
    context: context,
    publication: publication,
    repository: repository
  } do
    {:ok, snapshot} = Registry.build([OpenPullRequest])
    context = approve(context)
    call = call("open-refused", context)

    repository
    |> Ecto.Changeset.change(pull_requests_enabled: false)
    |> Repo.update!()

    assert {:ok, disabled} = Runner.run(snapshot, call, context)
    assert disabled["status"] == "refused"
    assert disabled["error"]["code"] == "pull_requests_disabled"
    assert disabled["result"]["protected_branch"] == publication.branch
    assert disabled["result"]["repository"]

    repository
    |> then(&Repo.get!(OpenAgents.Repositories.Repository, &1.id))
    |> Ecto.Changeset.change(pull_requests_enabled: true)
    |> Repo.update!()

    stale_oid = String.duplicate("d", 40)

    write_wal(repository.storage_key, [
      %{
        "refs/heads/main" => String.duplicate("a", 40),
        "refs/heads/#{publication.branch}" => stale_oid
      }
    ])

    assert {:ok, stale} = Runner.run(snapshot, call, context)
    assert stale["status"] == "refused"
    assert stale["error"]["code"] == "publication_receipt_stale"
  end

  test "Ox Alpha completes an approved pull request through the Responses tool loop", %{
    context: context,
    publication: publication
  } do
    arguments =
      Jason.encode!(%{
        "publication_receipt_ref" => "repository-publication:#{publication.id}",
        "title" => "Open the published workspace",
        "body" => "Review the approved workspace publication.",
        "draft" => true
      })

    provider_output = [
      %{
        "type" => "reasoning",
        "id" => "rs_open_pr",
        "status" => "completed",
        "summary" => [
          %{"type" => "summary_text", "text" => "Open the approved publication for review."}
        ],
        "encrypted_content" => "encrypted-open-pr-reasoning"
      },
      %{
        "type" => "function_call",
        "id" => "fc_open_pr",
        "call_id" => "call_open_pr",
        "name" => "open_pull_request",
        "arguments" => arguments,
        "status" => "completed"
      }
    ]

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/responses"
      assert Enum.map(conn.body_params["tools"], & &1["name"]) == ["open_pull_request"]

      body =
        sse(%{
          "type" => "response.created",
          "response" => %{
            "id" => "resp_open_pr",
            "object" => "response",
            "status" => "in_progress",
            "model" => "stealth/ox-alpha",
            "output" => []
          }
        }) <>
          sse(%{
            "type" => "response.in_progress",
            "response" => %{
              "id" => "resp_open_pr",
              "object" => "response",
              "status" => "in_progress",
              "model" => "stealth/ox-alpha",
              "output" => []
            }
          }) <>
          sse(%{
            "type" => "response.output_item.added",
            "response_id" => "resp_open_pr",
            "output_index" => 0,
            "item" => %{
              "type" => "reasoning",
              "id" => "rs_open_pr",
              "status" => "in_progress",
              "summary" => []
            }
          }) <>
          sse(%{
            "type" => "response.reasoning_summary_text.delta",
            "response_id" => "resp_open_pr",
            "item_id" => "rs_open_pr",
            "output_index" => 0,
            "summary_index" => 0,
            "delta" => "Open the approved publication for review."
          }) <>
          sse(%{
            "type" => "response.output_item.done",
            "response_id" => "resp_open_pr",
            "output_index" => 0,
            "item" => Enum.at(provider_output, 0)
          }) <>
          sse(%{
            "type" => "response.output_item.added",
            "response_id" => "resp_open_pr",
            "output_index" => 1,
            "item" => %{
              "type" => "function_call",
              "id" => "fc_open_pr",
              "call_id" => "call_open_pr",
              "name" => "open_pull_request",
              "arguments" => "",
              "status" => "in_progress"
            }
          }) <>
          sse(%{
            "type" => "response.function_call_arguments.delta",
            "response_id" => "resp_open_pr",
            "item_id" => "fc_open_pr",
            "output_index" => 1,
            "delta" => arguments
          }) <>
          sse(%{
            "type" => "response.function_call_arguments.done",
            "response_id" => "resp_open_pr",
            "item_id" => "fc_open_pr",
            "output_index" => 1,
            "arguments" => arguments
          }) <>
          sse(%{
            "type" => "response.output_item.done",
            "response_id" => "resp_open_pr",
            "output_index" => 1,
            "item" => Enum.at(provider_output, 1)
          }) <>
          sse(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_open_pr",
              "object" => "response",
              "status" => "completed",
              "model" => "stealth/ox-alpha",
              "output" => provider_output
            }
          }) <> "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      [user_input | replayed_output] = conn.body_params["input"]

      assert user_input["content"] == [
               %{"type" => "input_text", "text" => "Open the approved publication."}
             ]

      assert Enum.take(replayed_output, 2) == provider_output

      assert %{
               "type" => "function_call_output",
               "call_id" => "call_open_pr",
               "output" => tool_output
             } = List.last(replayed_output)

      assert %{
               "status" => "succeeded",
               "result" => %{
                 "repository" => _,
                 "url" => url,
                 "head" => %{"oid" => _}
               },
               "target_receipt_refs" => receipt_refs
             } = Jason.decode!(tool_output)

      assert url =~ "/pulls/"
      assert "repository-publication:#{publication.id}" in receipt_refs

      body =
        sse(%{
          "type" => "response.content_part.delta",
          "delta" => "I opened the approved draft pull request."
        }) <>
          sse(%{
            "type" => "response.completed",
            "response" => %{
              "object" => "response",
              "status" => "completed",
              "model" => "stealth/ox-alpha",
              "output" => [
                %{
                  "type" => "message",
                  "id" => "msg_open_pr_complete",
                  "role" => "assistant",
                  "status" => "completed",
                  "content" => [
                    %{
                      "type" => "output_text",
                      "text" => "I opened the approved draft pull request.",
                      "annotations" => []
                    }
                  ]
                }
              ]
            }
          }) <> "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    parent = self()
    assert {:ok, snapshot} = Registry.build([OpenPullRequest])

    assert {:ok, %{"assistant_content" => "I opened the approved draft pull request."}} =
             OpenRouter.stream(
               %{
                 "model" => "stealth/ox-alpha",
                 "messages" => [
                   %{"role" => "user", "content" => "Open the approved publication."}
                 ]
               },
               &send(parent, {:openrouter_event, &1}),
               api_key: "test-openrouter-key",
               tool_registry_snapshot: snapshot,
               tool_execution_context: approve(context),
               request_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_receive {:openrouter_event,
                    {:tool_call_started,
                     %{"call_id" => "call_open_pr", "name" => "open_pull_request"}}}

    assert_receive {:openrouter_event,
                    {:tool_call_completed,
                     %{"call_id" => "call_open_pr", "output" => tool_output}}}

    assert %{"status" => "succeeded", "result" => %{"url" => url}} =
             Jason.decode!(tool_output)

    assert url =~ "/pulls/"
  end

  defp approve(context) do
    receipt = OpenPullRequest.approval_receipt(context.scope_ref, "approval:open-pull-request")
    %{context | approval_receipts: [receipt]}
  end

  defp call(call_id, context, publication \\ nil) do
    publication = publication || publication_for(context)

    %{
      call_id: call_id,
      name: "open_pull_request",
      version: 1,
      raw_arguments:
        Jason.encode!(%{
          "publication_receipt_ref" => "repository-publication:#{publication.id}",
          "title" => "Open a draft pull request",
          "body" => "Review the published chat workspace."
        })
    }
  end

  defp publication_for(context) do
    Repo.one!(
      from publication in RepositoryPublication,
        where: publication.conversation_id == ^context.conversation_id,
        order_by: [asc: publication.inserted_at],
        limit: 1
    )
  end

  defp publication_fixture(repository, user, conversation_id, workspace_ref, branch, oid, wal_seq) do
    digest = :crypto.hash(:sha256, "#{conversation_id}:#{wal_seq}") |> Base.encode16(case: :lower)

    %RepositoryPublication{}
    |> RepositoryPublication.changeset(%{
      repository_id: repository.id,
      owner_user_id: user.id,
      conversation_id: conversation_id,
      workspace_ref: workspace_ref,
      idempotency_key: digest,
      argument_digest: digest,
      message: "Publish chat workspace",
      branch: branch,
      published_oid: oid,
      state: "accepted",
      wal_seq: wal_seq,
      result: %{
        "compare_url" =>
          "/#{repository.owner}/#{repository.name}/compare/#{repository.default_branch}...#{branch}",
        "summary" => %{"files_changed" => 2, "insertions" => 4, "deletions" => 1},
        "receipt" => %{"wal_seq" => wal_seq, "oid" => oid}
      }
    })
    |> Repo.insert!()
  end

  defp write_wal(storage_key, refs_by_sequence) do
    WAL.delete_repo(storage_key)

    index =
      Enum.with_index(refs_by_sequence)
      |> Enum.reduce(WAL.new_index(), fn {refs, sequence}, index ->
        WAL.append_entry(index, %{
          "seq" => sequence,
          "object" =>
            "entries/#{String.pad_leading(Integer.to_string(sequence), 8, "0")}-000000000000",
          "refs" => refs,
          "principal" => "test",
          "pushed_at" => "2026-08-23T00:00:00Z"
        })
      end)

    assert {:ok, _generation} = WAL.cas_index(storage_key, :none, index)
  end

  defp sse(event), do: "data: #{Jason.encode!(event)}\n\n"
end
