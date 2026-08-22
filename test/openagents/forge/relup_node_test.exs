defmodule OpenAgents.Forge.RelupNodeTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.RelupNode
  alias OpenAgents.ReleaseState
  alias OpenAgents.ReleaseState.State
  alias OpenAgents.Test.ReleaseHandler

  describe "a schema 1 to schema 2 upgrade" do
    setup do
      start_supervised!(
        {ReleaseHandler, %{releases: [{~c"openagents", ~c"0.1.0", [], :permanent}]}}
      )

      root = release_root()

      artifact = "immutable release artifact"

      request = %{
        release_name: "openagents",
        from_version: "0.1.0",
        to_version: "0.2.0",
        from_state_version: 1,
        to_state_version: 2,
        artifact_bytes: artifact,
        artifact_digest: sha256(artifact)
      }

      opts = [
        release_root: root,
        release_handler: ReleaseHandler,
        generate_config: fn _version -> :ok end,
        health: fn -> %{"ready" => true} end,
        state: fn -> %{schema_version: 2} end
      ]

      %{root: root, request: request, opts: opts}
    end

    test "restages the consumed artifact from immutable cache", %{
      root: root,
      request: request,
      opts: opts
    } do
      assert {:ok, %{"phase" => "staged"}} = RelupNode.stage(request, opts)
      assert {:ok, %{"phase" => "stage_verified"}} = RelupNode.verify_stage(request, opts)
      assert {:ok, %{"phase" => "unpacked"}} = RelupNode.unpack(request, opts)

      staged = Path.join([root, "releases", "openagents-0.2.0.tar.gz"])
      File.rm!(staged)

      assert {:ok, %{"phase" => "unpacked", "restaged" => true}} = RelupNode.unpack(request, opts)
      assert File.read!(staged) == request.artifact_bytes
    end

    test "checks, installs, verifies, and makes the release permanent", %{
      request: request,
      opts: opts
    } do
      assert {:ok, _result} = RelupNode.stage(request, opts)
      assert {:ok, _result} = RelupNode.unpack(request, opts)
      assert {:ok, %{"phase" => "checked"}} = RelupNode.check_install(request, opts)
      assert {:ok, %{"phase" => "installed"}} = RelupNode.install(request, opts)
      assert {:ok, %{"phase" => "verified"}} = RelupNode.verify(request, :current, opts)
      assert {:ok, %{"phase" => "permanent"}} = RelupNode.make_permanent(request, opts)
      assert {:ok, %{"phase" => "verified"}} = RelupNode.verify(request, :permanent, opts)
    end

    test "refuses a candidate whose staged bytes are not the requested artifact", %{
      request: request,
      opts: opts
    } do
      assert {:error, :artifact_digest_mismatch} =
               RelupNode.stage(%{request | artifact_bytes: "other bytes"}, opts)
    end

    test "refuses a version already unpacked from different bytes", %{
      request: request,
      opts: opts
    } do
      assert {:ok, _result} = RelupNode.stage(request, opts)
      assert {:ok, _result} = RelupNode.unpack(request, opts)

      recut = "0.2.0 rebuilt from another revision"
      recut = %{request | artifact_bytes: recut, artifact_digest: sha256(recut)}

      assert {:ok, _result} = RelupNode.stage(recut, opts)
      assert {:error, :unpacked_version_conflict} = RelupNode.unpack(recut, opts)
    end
  end

  describe "a same-schema pair through forward, reverse, and forward again" do
    setup do
      state = start_supervised!({ReleaseState, name: nil})
      :ok = ReleaseState.observe("retained", state)

      # The instructions the appup emits for a 2 -> 2 pair. `AppupTest` proves
      # the generator emits exactly these extras in each direction.
      installer = fn
        "0.3.0" -> migrate(state, ~c"0.2.0", schema_version: 2)
        "0.2.0" -> migrate(state, {:down, ~c"0.3.0"}, schema_version: 2)
      end

      start_supervised!(
        {ReleaseHandler,
         %{
           releases: [{~c"openagents", ~c"0.2.0", [], :permanent}],
           pair: {"0.2.0", "0.3.0"},
           on_install: installer
         }}
      )

      artifact = "immutable 0.3.0 artifact"

      request = %{
        release_name: "openagents",
        from_version: "0.2.0",
        to_version: "0.3.0",
        from_state_version: 2,
        to_state_version: 2,
        artifact_bytes: artifact,
        artifact_digest: sha256(artifact)
      }

      opts = [
        release_root: release_root(),
        release_handler: ReleaseHandler,
        generate_config: fn _version -> :ok end,
        health: fn -> %{"ready" => true} end,
        state: fn -> ReleaseState.snapshot(state) end
      ]

      %{state: state, request: request, opts: opts}
    end

    test "verifies forward, reverses without corrupting state, and re-upgrades", %{
      state: state,
      request: request,
      opts: opts
    } do
      assert {:ok, _result} = RelupNode.stage(request, opts)
      assert {:ok, _result} = RelupNode.verify_stage(request, opts)
      assert {:ok, _result} = RelupNode.unpack(request, opts)
      assert {:ok, _result} = RelupNode.check_install(request, opts)
      assert {:ok, _result} = RelupNode.install(request, opts)
      assert {:ok, %{"phase" => "verified"}} = RelupNode.verify(request, :current, opts)
      assert {:ok, _result} = RelupNode.make_permanent(request, opts)
      assert {:ok, %{"phase" => "verified"}} = RelupNode.verify(request, :permanent, opts)

      # `reverse/2` installs 0.2.0, checks health and schema, then restores
      # permanence. Before the target schema became explicit this left the
      # process on schema 1, so verify_reverse_health/2 failed with
      # :reverse_state_version_mismatch and permanence was never restored.
      assert {:ok, %{"phase" => "reversed", "restored" => true}} =
               RelupNode.reverse(request, opts)

      assert %State{schema_version: 2, observations: ["retained"], integrity: integrity} =
               ReleaseState.snapshot(state)

      assert is_binary(integrity)

      assert {:ok, _result} = RelupNode.install(request, opts)
      assert {:ok, %{"phase" => "verified"}} = RelupNode.verify(request, :current, opts)
      assert {:ok, _result} = RelupNode.make_permanent(request, opts)
      assert {:ok, %{"phase" => "verified"}} = RelupNode.verify(request, :permanent, opts)

      assert %State{schema_version: 2, observations: ["retained"]} = ReleaseState.snapshot(state)
    end
  end

  defp migrate(pid, version, extra) do
    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, ReleaseState, version, extra)
    :ok = :sys.resume(pid)
  end

  defp release_root do
    root =
      Path.join(System.tmp_dir!(), "openagents-relup-node-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "releases"))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
