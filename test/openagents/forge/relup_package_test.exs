defmodule OpenAgents.Forge.RelupPackageTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.RelupPackage

  @from_sha String.duplicate("a", 40)
  @to_sha String.duplicate("b", 40)
  @system "x86_64-pc-linux-gnu"

  test "loads a package bound to the running revision and target system" do
    directory = package_directory()
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:ok, request} =
             RelupPackage.load(directory,
               current_revision: @from_sha,
               system_architecture: @system,
               expected_nodes: [:second@local, :first@local]
             )

    assert request.sha == @to_sha
    assert request.from_version == "0.2.0"
    assert request.to_version == "0.3.0"
    assert request.expected_nodes == [:first@local, :second@local]
    assert request.artifact_bytes == "target release"
  end

  test "refuses a package for another revision, platform, or artifact" do
    directory = package_directory()
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:error, :running_revision_mismatch} =
             RelupPackage.load(directory,
               current_revision: String.duplicate("c", 40),
               system_architecture: @system
             )

    assert {:error, :target_system_mismatch} =
             RelupPackage.load(directory,
               current_revision: @from_sha,
               system_architecture: "aarch64-apple-darwin"
             )

    File.write!(Path.join(directory, "openagents-0.3.0.tar.gz"), "changed")

    assert {:error, :target_artifact_digest_mismatch} =
             RelupPackage.load(directory,
               current_revision: @from_sha,
               system_architecture: @system
             )
  end

  defp package_directory do
    directory =
      Path.join(
        System.tmp_dir!(),
        "openagents-relup-package-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    artifact = "target release"
    File.write!(Path.join(directory, "openagents-0.3.0.tar.gz"), artifact)

    manifest = %{
      "schema" => "openagents.relup-package.v1",
      "release_name" => "openagents",
      "from_revision" => @from_sha,
      "to_revision" => @to_sha,
      "from_version" => "0.2.0",
      "to_version" => "0.3.0",
      "from_state_version" => 2,
      "to_state_version" => 2,
      "from_artifact_digest" => String.duplicate("d", 64),
      "to_artifact_digest" => sha256(artifact),
      "relup_digest" => String.duplicate("e", 64),
      "target_system" => @system
    }

    File.write!(Path.join(directory, "package.json"), Jason.encode!(manifest))
    directory
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
