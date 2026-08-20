defmodule OpenAgents.Forge.GateReceiptTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.GateReceipt

  @sha String.duplicate("a", 40)
  @stages ~w(
    compile
    production_compile
    precommit
    cluster
    javascript
    direct_transaction
    relup
    version_chain
    interrupted_install
    rolling_replacement
    contracts
    staging_infra
    release_smoke
  )

  test "accepts only a complete receipt bound to the requested SHA" do
    root = temporary_root()
    path = GateReceipt.path(@sha, repo_root: root)
    File.mkdir_p!(Path.dirname(path))

    receipt = %{
      "schema" => "openagents.release-gate.v1",
      "git_sha" => @sha,
      "status" => "passed",
      "stages" => Map.new(@stages, &{&1, %{"status" => "passed"}})
    }

    File.write!(path, Jason.encode!(receipt))
    assert {:ok, ^receipt} = GateReceipt.verify(@sha, repo_root: root)

    assert {:error, :missing_gate_receipt} =
             GateReceipt.verify(String.duplicate("b", 40), repo_root: root)
  end

  test "rejects an incomplete receipt" do
    root = temporary_root()
    path = GateReceipt.path(@sha, repo_root: root)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "schema" => "openagents.release-gate.v1",
        "git_sha" => @sha,
        "status" => "passed",
        "stages" => %{}
      })
    )

    assert {:error, :incomplete_gate_receipt} = GateReceipt.verify(@sha, repo_root: root)
  end

  test "never lets an emergency reason bypass Git SHA validation" do
    assert {:error, :invalid_git_sha} =
             GateReceipt.verify("not-a-sha", emergency_override: "operator recovery")
  end

  defp temporary_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "openagents-gate-receipt-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
