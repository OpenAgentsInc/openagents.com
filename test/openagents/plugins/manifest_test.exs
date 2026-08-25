defmodule OpenAgents.Plugins.ManifestTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Plugins.Manifest

  @fixture_path "test/fixtures/plugin_manifest.json"

  defp shipping_manifest do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  test "accepts the shipping git-lost-work manifest" do
    manifest = shipping_manifest()
    assert {:ok, validated} = Manifest.validate(manifest)
    assert validated["name"] == "git_lost_work"
    assert validated["version"] == "0.1.0"
    assert validated["price_msats"] == nil
    assert validated["license"] == "Apache-2.0"
  end

  test "rejects a manifest with an invalid name" do
    manifest = put_in(shipping_manifest(), ["name"], "Git Lost Work")
    assert {:error, %Manifest.ValidationError{field: "name"}} = Manifest.validate(manifest)
  end

  test "rejects a manifest with an invalid version" do
    manifest = put_in(shipping_manifest(), ["version"], "0.1")
    assert {:error, %Manifest.ValidationError{field: "version"}} = Manifest.validate(manifest)
  end

  test "rejects a manifest with a malformed artifact digest" do
    manifest = put_in(shipping_manifest(), ["artifact", "digest"], "sha256:deadbeef")

    assert {:error, %Manifest.ValidationError{field: "artifact.digest"}} =
             Manifest.validate(manifest)
  end

  test "rejects an artifact digest missing the sha256 prefix" do
    manifest =
      put_in(
        shipping_manifest(),
        ["artifact", "digest"],
        "366760578cb1d83ab49a0819150308014401972907a44c89618e74de3a906c36"
      )

    assert {:error, %Manifest.ValidationError{field: "artifact.digest"}} =
             Manifest.validate(manifest)
  end

  test "rejects an invalid interface.input schema" do
    manifest = put_in(shipping_manifest(), ["interface", "input"], "not a schema")

    assert {:error, %Manifest.ValidationError{field: "interface.input"}} =
             Manifest.validate(manifest)
  end

  test "rejects invalid nested capability types" do
    manifest = put_in(shipping_manifest(), ["capabilities", "timeout_ms"], -1)

    assert {:error, %Manifest.ValidationError{field: "capabilities.timeout_ms"}} =
             Manifest.validate(manifest)
  end

  test "rejects a capability host that is not a string" do
    manifest = put_in(shipping_manifest(), ["capabilities", "hosts"], [123])

    assert {:error, %Manifest.ValidationError{field: "capabilities.hosts.0"}} =
             Manifest.validate(manifest)
  end

  test "rejects a reserved price that is not null or a non-negative integer" do
    manifest = put_in(shipping_manifest(), ["price_msats"], "free")
    assert {:error, %Manifest.ValidationError{field: "price_msats"}} = Manifest.validate(manifest)
  end

  test "rejects a reserved license that is not null or a string" do
    manifest = put_in(shipping_manifest(), ["license"], 123)
    assert {:error, %Manifest.ValidationError{field: "license"}} = Manifest.validate(manifest)
  end

  test "rejects unknown top-level fields" do
    manifest = Map.put(shipping_manifest(), "extra", true)
    assert {:error, %Manifest.ValidationError{}} = Manifest.validate(manifest)
  end

  test "rejects a non-map manifest" do
    assert {:error, %Manifest.ValidationError{field: "root"}} = Manifest.validate("not a map")
  end

  test "rejects a missing required top-level field" do
    manifest = Map.delete(shipping_manifest(), "manifest_version")

    assert {:error, %Manifest.ValidationError{field: "manifest_version"}} =
             Manifest.validate(manifest)
  end

  test "rejects an artifact missing a nested required field" do
    manifest = put_in(shipping_manifest(), ["artifact"], %{"path" => "git_lost_work.wasm"})

    assert {:error, %Manifest.ValidationError{field: "artifact.digest"}} =
             Manifest.validate(manifest)
  end

  test "rejects an interface input schema missing a type" do
    manifest = put_in(shipping_manifest(), ["interface", "input"], %{"properties" => %{}})

    assert {:error, %Manifest.ValidationError{field: "interface.input.type"}} =
             Manifest.validate(manifest)
  end

  test "rejects an invalid nested schema type" do
    manifest =
      put_in(
        shipping_manifest(),
        ["interface", "input", "properties", "max_lost_commits", "type"],
        "notype"
      )

    assert {:error,
            %Manifest.ValidationError{field: "interface.input.properties.max_lost_commits.type"}} =
             Manifest.validate(manifest)
  end

  test "rejects a mount that is not read-only" do
    manifest =
      put_in(shipping_manifest(), ["capabilities", "mounts"], [
        %{"path" => ".", "readonly" => false}
      ])

    assert {:error, %Manifest.ValidationError{field: "capabilities.mounts.0.readonly"}} =
             Manifest.validate(manifest)
  end

  test "rejects a mount readonly that is not a literal boolean" do
    manifest =
      put_in(shipping_manifest(), ["capabilities", "mounts"], [
        %{"path" => ".", "readonly" => "true"}
      ])

    assert {:error, %Manifest.ValidationError{field: "capabilities.mounts.0.readonly"}} =
             Manifest.validate(manifest)
  end

  test "rejects a surface with a malformed slash command" do
    manifest =
      put_in(
        shipping_manifest(),
        ["surfaces"],
        [
          %{
            "name" => "chat",
            "description" => "A chat surface",
            "slash_commands" => [%{"description" => "missing command"}]
          }
        ]
      )

    assert {:error, %Manifest.ValidationError{field: "surfaces.0.slash_commands.0.command"}} =
             Manifest.validate(manifest)
  end
end
