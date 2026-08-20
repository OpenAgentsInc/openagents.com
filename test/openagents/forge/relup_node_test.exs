defmodule OpenAgents.Forge.RelupNodeTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.RelupNode
  alias OpenAgents.Test.ReleaseHandler

  setup do
    start_supervised!(
      {ReleaseHandler, %{releases: [{~c"openagents", ~c"0.1.0", [], :permanent}]}}
    )

    root =
      Path.join(System.tmp_dir!(), "openagents-relup-node-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "releases"))
    on_exit(fn -> File.rm_rf!(root) end)

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

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
