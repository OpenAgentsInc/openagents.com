defmodule OpenAgents.Tools.PublishChangesTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Tools.{
    ExecutionContext,
    PublishChanges,
    Registry,
    Runner,
    WorkspacePublication
  }

  setup do
    base = Path.join(System.tmp_dir!(), "publish-changes-#{System.unique_integer([:positive])}")
    root = Path.join(base, "workspace")
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(root)

    git!(root, ["init", "-b", "main"])
    File.write!(Path.join(root, "README.md"), "initial\n")
    git!(root, ["add", "README.md"])

    git!(root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.com",
      "commit",
      "-m",
      "Initial"
    ])

    System.cmd("git", ["clone", "--bare", root, remote]) |> successful!()

    user = repository_user_fixture("publisher")
    repository = repository_with_member_fixture(user, %{owner: "OpenAgentsInc"})

    previous_url = Application.get_env(:openagents, :workspace_publish_url_resolver)
    previous_receipt = Application.get_env(:openagents, :workspace_publish_receipt_resolver)
    Application.put_env(:openagents, :workspace_publish_url_resolver, fn _repo -> remote end)

    Application.put_env(:openagents, :workspace_publish_receipt_resolver, fn _repo, branch, oid ->
      {:ok,
       %{
         "schema" => "openagents.forge_push_receipt.v1",
         "id" => "receipt-test",
         "wal_seq" => 17,
         "ref" => "refs/heads/#{branch}",
         "oid" => oid
       }}
    end)

    on_exit(fn ->
      restore(:workspace_publish_url_resolver, previous_url)
      restore(:workspace_publish_receipt_resolver, previous_receipt)
      File.rm_rf(base)
    end)

    context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:publish",
      authorities: MapSet.new(["repository.write"]),
      owner_user_id: user.id,
      conversation_id: Ecto.UUID.generate(),
      workspace: %{
        "type" => "repository_workspace",
        "root" => root,
        "canonical" => false,
        "read_only" => false,
        "workspace_ref" => "workspace:publish",
        "repository_id" => repository.id
      }
    }

    %{context: context, root: root, remote: remote, repository: repository}
  end

  test "publishes all changes to only the server-assigned branch and returns receipts", %{
    context: context,
    root: root,
    remote: remote,
    repository: repository
  } do
    File.write!(Path.join(root, "README.md"), "changed\n")
    File.write!(Path.join(root, "new.txt"), "new\n")
    assert {:ok, digest} = WorkspacePublication.workspace_digest(context)

    assert {:ok, execution} =
             PublishChanges.execute(
               %{"message" => "Publish workspace", "expected_workspace_digest" => digest},
               context
             )

    result = execution.result
    branch = WorkspacePublication.branch(context)
    assert result["branch"] == branch
    assert result["repository"] == "#{repository.namespace.slug}/#{repository.name}"
    assert result["summary"] == %{"files_changed" => 2, "insertions" => 2, "deletions" => 1}
    assert result["receipt"]["wal_seq"] == 17
    assert Enum.any?(execution.target_receipt_refs, &String.starts_with?(&1, "forge-push:"))

    published = ls_remote!(remote, branch)
    assert published == result["published_oid"]
    assert ls_remote!(remote, "main") == result["source_oid"]
    assert git!(root, ["status", "--porcelain"]) =~ "README.md"
  end

  test "retries are deterministic and do not create a second commit", %{
    context: context,
    root: root
  } do
    File.write!(Path.join(root, "README.md"), "changed\n")
    assert {:ok, first} = WorkspacePublication.publish(context, "Retry-safe publication", nil)
    assert {:ok, second} = WorkspacePublication.publish(context, "Retry-safe publication", nil)
    assert first == second
  end

  test "refuses stale, empty, read-only, unbound, and unauthorized workspaces", %{
    context: context,
    root: root
  } do
    assert {:error, :nothing_to_publish} =
             WorkspacePublication.publish(context, "No changes", nil)

    File.write!(Path.join(root, "README.md"), "changed\n")

    assert {:error, :stale_workspace_digest} =
             WorkspacePublication.publish(context, "Stale", String.duplicate("0", 64))

    assert {:error, :workspace_read_only} =
             WorkspacePublication.publish(
               put_in(context.workspace["read_only"], true),
               "Read only",
               nil
             )

    assert {:error, :repository_workspace_unavailable} =
             WorkspacePublication.publish(%{context | workspace: nil}, "Unbound", nil)

    stranger = repository_user_fixture("stranger")

    assert {:error, :repository_write_refused} =
             WorkspacePublication.publish(
               %{context | owner_user_id: stranger.id},
               "No access",
               nil
             )
  end

  test "runner requires authority and an exact publication approval", %{
    context: context,
    root: root
  } do
    File.write!(Path.join(root, "README.md"), "approved\n")
    assert {:ok, snapshot} = Registry.build([PublishChanges])

    call = %{
      call_id: "call-publish",
      name: "publish_changes",
      version: 1,
      raw_arguments: Jason.encode!(%{"message" => "Approved publication"})
    }

    assert {:ok, no_approval} = Runner.run(snapshot, call, context)
    assert no_approval["error"]["code"] == "module_approval_required"

    receipt = WorkspacePublication.approval_receipt(context.scope_ref, "approval:publish")

    assert {:ok, no_authority} =
             Runner.run(snapshot, call, %{
               context
               | authorities: MapSet.new(),
                 approval_receipts: [receipt]
             })

    assert no_authority["error"]["code"] == "authority_refused"

    assert {:ok, published} =
             Runner.run(snapshot, call, %{context | approval_receipts: [receipt]})

    assert published["status"] == "succeeded"
    assert published["result"]["branch"] == WorkspacePublication.branch(context)
  end

  test "the model cannot supply a repository, remote, or branch", %{context: context, root: root} do
    File.write!(Path.join(root, "README.md"), "changed\n")
    assert {:ok, snapshot} = Registry.build([PublishChanges])
    receipt = WorkspacePublication.approval_receipt(context.scope_ref, "approval:publish")

    for forbidden <- ["repository", "remote", "branch"] do
      call = %{
        call_id: "call-#{forbidden}",
        name: "publish_changes",
        version: 1,
        raw_arguments: Jason.encode!(%{"message" => "Attempt", forbidden => "attacker/value"})
      }

      assert {:ok, refused} =
               Runner.run(snapshot, call, %{context | approval_receipts: [receipt]})

      assert refused["error"]["code"] == "additional_property_not_allowed"
    end
  end

  defp git!(root, args) do
    System.cmd("git", ["-C", root | args], stderr_to_stdout: true) |> successful!()
  end

  defp successful!({output, 0}), do: String.trim(output)

  defp ls_remote!(remote, branch) do
    remote
    |> then(&System.cmd("git", ["ls-remote", &1, "refs/heads/#{branch}"]))
    |> successful!()
    |> String.split()
    |> List.first()
  end

  defp restore(key, nil), do: Application.delete_env(:openagents, key)
  defp restore(key, value), do: Application.put_env(:openagents, key, value)
end
