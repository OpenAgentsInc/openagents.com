defmodule OpenAgents.Tools.WorkspaceToolsTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Tools.{
    ExecutionContext,
    Registry,
    Runner,
    WorkspaceEdit,
    WorkspaceFiles,
    WorkspaceRead,
    WorkspaceWrite
  }

  setup do
    base = Path.join(System.tmp_dir!(), "workspace-tools-#{System.unique_integer([:positive])}")
    root = Path.join(base, "workspace")
    snapshots = Path.join(base, "snapshots")
    File.mkdir_p!(root)
    previous = Application.get_env(:openagents, :workspace_snapshot_dir)
    Application.put_env(:openagents, :workspace_snapshot_dir, snapshots)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:openagents, :workspace_snapshot_dir, previous),
        else: Application.delete_env(:openagents, :workspace_snapshot_dir)

      File.rm_rf(base)
    end)

    context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:test",
      authorities: MapSet.new(["repository.read", "repository.write"]),
      workspace: %{
        "type" => "repository_workspace",
        "root" => root,
        "canonical" => false,
        "read_only" => false,
        "workspace_ref" => "workspace:test"
      }
    }

    %{context: context, root: root, snapshots: snapshots}
  end

  test "read returns stable line continuation and enforces both bounds", %{
    context: context,
    root: root
  } do
    File.write!(Path.join(root, "lines.txt"), Enum.map_join(1..2_005, "", &"line-#{&1}\n"))
    assert {:ok, result} = WorkspaceRead.execute(%{"path" => "lines.txt"}, context)
    assert result.result["line_count"] == 2_000
    assert result.result["next_offset"] == 2_001

    assert {:ok, continued} =
             WorkspaceRead.execute(%{"path" => "lines.txt", "offset" => 2_001}, context)

    assert continued.result["content"] ==
             "line-2001\nline-2002\nline-2003\nline-2004\nline-2005\n"

    File.write!(
      Path.join(root, "bytes.txt"),
      String.duplicate("a", 30_000) <> "\n" <> String.duplicate("b", 30_000)
    )

    assert {:ok, bytes} = WorkspaceRead.execute(%{"path" => "bytes.txt"}, context)
    assert bytes.result["returned_bytes"] <= 50 * 1_024
    assert bytes.result["next_offset"] == 2

    File.write!(Path.join(root, "oversized-line.txt"), String.duplicate("x", 50 * 1_024 + 1))

    assert {:error, :workspace_line_too_large} =
             WorkspaceRead.execute(%{"path" => "oversized-line.txt"}, context)
  end

  test "read returns typed missing, directory, traversal, encoding, range, and symlink errors", %{
    context: context,
    root: root
  } do
    File.mkdir_p!(Path.join(root, "folder"))
    File.write!(Path.join(root, "binary"), <<255>>)
    outside = Path.join(Path.dirname(root), "outside")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(root, "link"))

    assert {:error, :workspace_file_not_found} =
             WorkspaceRead.execute(%{"path" => "missing"}, context)

    assert {:error, :workspace_path_is_directory} =
             WorkspaceRead.execute(%{"path" => "folder"}, context)

    assert {:error, :workspace_path_escape} =
             WorkspaceRead.execute(%{"path" => "../outside"}, context)

    assert {:error, :workspace_invalid_encoding} =
             WorkspaceRead.execute(%{"path" => "binary"}, context)

    assert {:error, :invalid_read_range} =
             WorkspaceRead.execute(%{"path" => "binary", "offset" => 0}, context)

    assert {:error, :workspace_symlink_refused} =
             WorkspaceRead.execute(%{"path" => "link"}, context)
  end

  test "read redacts credential-shaped text before returning it", %{
    context: context,
    root: root
  } do
    secret = "sk-or-v1-abcdefghijklmnopqrstuvwxyz012345"

    File.write!(
      Path.join(root, "secret.txt"),
      "token=#{secret}\nBearer opaque-token-value-123456\n"
    )

    assert {:ok, result} = WorkspaceRead.execute(%{"path" => "secret.txt"}, context)
    refute result.result["content"] =~ secret
    refute result.result["content"] =~ "opaque-token-value-123456"
    assert result.result["content"] =~ "[REDACTED]"
  end

  test "write creates parents, replaces files, and stores restorable snapshots outside the workspace",
       %{
         context: context,
         root: root,
         snapshots: snapshots
       } do
    assert {:ok, created} =
             WorkspaceWrite.execute(%{"path" => "deep/file.txt", "content" => "first"}, context)

    assert created.result["action"] == "created"
    assert created.result["prior_digest"] == nil
    assert File.read!(Path.join(root, "deep/file.txt")) == "first"

    assert {:ok, replaced} =
             WorkspaceWrite.execute(%{"path" => "deep/file.txt", "content" => "second"}, context)

    assert replaced.result["action"] == "replaced"
    assert replaced.result["prior_digest"] == WorkspaceFiles.digest("first")

    snapshot_id =
      String.replace_prefix(replaced.result["snapshot_ref"], "workspace-snapshot:", "")

    assert File.read!(Path.join([snapshots, snapshot_id, "content"])) == "first"
    refute File.exists?(Path.join(root, ".openagents"))
  end

  test "write refuses a host snapshot store inside the checkout", %{
    context: context,
    root: root
  } do
    Application.put_env(:openagents, :workspace_snapshot_dir, Path.join(root, "snapshots"))

    assert {:error, :workspace_snapshot_root_invalid} =
             WorkspaceWrite.execute(%{"path" => "file.txt", "content" => "content"}, context)

    refute File.exists?(Path.join(root, "file.txt"))
    refute File.exists?(Path.join(root, "snapshots"))
  end

  test "edit applies exact batches atomically and preserves BOM and CRLF", %{
    context: context,
    root: root
  } do
    original = <<0xEF, 0xBB, 0xBF>> <> "one\r\ntwo\r\nthree\r\n"
    File.write!(Path.join(root, "edit.txt"), original)

    assert {:ok, edited} =
             WorkspaceEdit.execute(
               %{
                 "path" => "edit.txt",
                 "expected_digest" => WorkspaceFiles.digest(original),
                 "edits" => [
                   %{"old_text" => "one", "new_text" => "ONE"},
                   %{"old_text" => "three", "new_text" => "THREE"}
                 ]
               },
               context
             )

    assert edited.result["replacements"] == 2

    assert File.read!(Path.join(root, "edit.txt")) ==
             <<0xEF, 0xBB, 0xBF>> <> "ONE\r\ntwo\r\nTHREE\r\n"
  end

  test "edit rejects ambiguous, overlapping, and stale batches without mutation", %{
    context: context,
    root: root
  } do
    path = Path.join(root, "edit.txt")
    File.write!(path, "aaa bbb aaa")
    digest = WorkspaceFiles.digest(File.read!(path))

    assert {:error, :ambiguous_match} =
             edit(context, digest, [%{"old_text" => "aaa", "new_text" => "x"}])

    assert {:error, :overlapping_edits} =
             edit(context, digest, [
               %{"old_text" => "aaa bbb", "new_text" => "x"},
               %{"old_text" => "bbb aaa", "new_text" => "y"}
             ])

    assert {:error, :stale_workspace_digest} =
             edit(context, String.duplicate("0", 64), [%{"old_text" => "bbb", "new_text" => "x"}])

    assert File.read!(path) == "aaa bbb aaa"
  end

  test "same-path edits serialize so one stale concurrent writer loses", %{
    context: context,
    root: root
  } do
    File.write!(Path.join(root, "edit.txt"), "value")
    digest = WorkspaceFiles.digest("value")
    parent = self()

    tasks =
      for replacement <- ["first", "second"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do: (:go ->
                         edit(context, digest, [
                           %{"old_text" => "value", "new_text" => replacement}
                         ]))
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, pid}
      send(pid, :go)
    end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_workspace_digest})) == 1
  end

  test "connected and canonical repository bindings cannot be mutated", %{
    context: context,
    root: root
  } do
    connected = %{context | workspace: %{"type" => "connected_forge_repository", "root" => root}}

    assert {:error, :workspace_required} =
             WorkspaceWrite.execute(%{"path" => "x", "content" => "x"}, connected)

    canonical = put_in(context.workspace["canonical"], true)

    assert {:error, :canonical_workspace_refused} =
             WorkspaceWrite.execute(%{"path" => "x", "content" => "x"}, canonical)

    read_only = put_in(context.workspace["read_only"], true)

    assert {:error, :workspace_read_only} =
             WorkspaceWrite.execute(%{"path" => "x", "content" => "x"}, read_only)

    assert {:error, :workspace_required} =
             WorkspaceWrite.execute(
               %{"path" => "x", "content" => "x", "root" => root},
               %{context | workspace: nil}
             )
  end

  test "write refuses symlink components", %{context: context, root: root} do
    outside = Path.join(Path.dirname(root), "outside-write")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "linked"))

    assert {:error, :workspace_symlink_refused} =
             WorkspaceWrite.execute(%{"path" => "linked/file", "content" => "x"}, context)

    refute File.exists?(Path.join(outside, "file"))
  end

  test "runner requires repository.write authority and an exact approval receipt", %{
    context: context
  } do
    assert {:ok, snapshot} = Registry.build([WorkspaceWrite])

    call = %{
      call_id: "call-workspace-write",
      name: "write",
      version: 1,
      raw_arguments: Jason.encode!(%{"path" => "approved.txt", "content" => "approved"})
    }

    assert {:ok, refused_approval} = Runner.run(snapshot, call, context)
    assert refused_approval["error"]["code"] == "module_approval_required"

    receipt = %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "exact_current_user_consent",
      "module_id" => WorkspaceWrite.specification().module_id,
      "version" => 1,
      "scope_ref" => context.scope_ref,
      "explicit" => true,
      "actor_type" => "person",
      "receipt_ref" => "approval:workspace-write"
    }

    assert {:ok, refused_authority} =
             Runner.run(snapshot, call, %{
               context
               | authorities: MapSet.new(),
                 approval_receipts: [receipt]
             })

    assert refused_authority["error"]["code"] == "authority_refused"

    assert {:ok, approved} =
             Runner.run(snapshot, call, %{context | approval_receipts: [receipt]})

    assert approved["status"] == "succeeded"
    assert approved["result"]["final_digest"] == WorkspaceFiles.digest("approved")
  end

  defp edit(context, digest, edits) do
    WorkspaceEdit.execute(
      %{"path" => "edit.txt", "expected_digest" => digest, "edits" => edits},
      context
    )
  end
end
