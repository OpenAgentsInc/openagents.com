defmodule OpenAgents.StagingCandidateContractTest do
  use ExUnit.Case, async: true

  test "the staging registry prevents tag movement and Terraform deletion" do
    terraform = File.read!("infra/staging/main.tf")
    safety_test = File.read!("infra/staging/tests/safety.tftest.hcl")

    assert terraform =~ "immutable_tags = true"
    assert terraform =~ ~s(deletion_policy        = "PREVENT")
    assert safety_test =~ "docker_config[0].immutable_tags"
    assert safety_test =~ "deletion_policy == \"PREVENT\""
  end

  test "the container build pins external inputs and distributed cookie admission" do
    dockerfile = File.read!("Dockerfile")
    release_config = File.read!("mix.exs")
    release_environment = File.read!("rel/env.sh.eex")

    assert dockerfile =~ ~r/BUILDER_IMAGE=.*@sha256:[0-9a-f]{64}/
    assert dockerfile =~ ~r/RUNNER_IMAGE=.*@sha256:[0-9a-f]{64}/
    assert dockerfile =~ "snapshot.debian.org/archive/debian/"
    assert dockerfile =~ ~s(mix local.hex "${HEX_VERSION}" --force)
    assert dockerfile =~ "--sha512 \"${REBAR3_SHA512}\""

    assert dockerfile =~
             ~s("${TAILWIND_SHA256}" "/app/_build/tailwind-linux-x64-${TAILWIND_VERSION}")

    assert dockerfile =~ ~s("${ESBUILD_SHA256}" "/app/_build/esbuild-linux-x64")
    assert dockerfile =~ "sha256sum --check --strict"
    assert dockerfile =~ "SOURCE_DATE_EPOCH"
    assert release_config =~ ~s(cookie: "openagents-nondistributed-placeholder")

    assert release_environment =~
             ~s(RELEASE_COOKIE:?RELEASE_COOKIE is required for a distributed node)
  end

  test "the isolated builder loads runtime configuration without the web role" do
    dockerfile = File.read!("Dockerfile")
    runtime_config = File.read!("config/runtime.exs")

    assert dockerfile =~ "FROM builder AS forge-builder"
    assert dockerfile =~ "ENV OPENAGENTS_RUNTIME_ROLE=builder"
    assert dockerfile =~ ~s(mix", "run", "--no-compile", "--no-start")
    assert runtime_config =~ ~s("builder" -> :builder)
  end

  test "fleet discovery and release identities use the same stable private addresses" do
    terraform = File.read!("infra/staging/main.tf")
    startup = File.read!("infra/staging/templates/fleet-startup.sh.tftpl")
    outputs = File.read!("infra/staging/outputs.tf")

    assert terraform =~ "network_cidr = var.network_cidr"
    assert startup =~ "instance_ip=$(metadata instance/network-interfaces/0/ip)"
    assert startup =~ ~s(iptables -C INPUT -s "${network_cidr}")
    assert startup =~ "--dports 4000,4369,9100:9115 -j ACCEPT"
    assert startup =~ "DNS_CLUSTER_QUERY=openagents-fleet.staging.internal"
    assert startup =~ "OPENAGENTS_NODE_HOST=$instance_ip"
    assert startup =~ "RELEASE_NODE=openagents@$instance_ip"
    refute startup =~ "RELEASE_NODE=openagents@$instance_name.staging.internal"
    assert outputs =~ ~s("openagents@${instance_ip}" => instance_name)
  end

  test "candidate publication binds exact immutable registry and artifact identities" do
    publisher = File.read!("ops/staging/publish-candidate.sh")
    sbom = File.read!("ops/staging/generate-sbom.sh")

    assert publisher =~ "refs/remotes/origin/main"
    assert publisher =~ "ops/ci/gate.sh --verify"
    assert publisher =~ "platform=linux/amd64"
    assert publisher =~ ~s(docker pull --platform "$platform")
    assert publisher =~ ".dockerConfig.immutableTags == true"
    assert publisher =~ ~s(application_tag="${application_repository}:${git_sha}")
    assert publisher =~ ~s(builder_tag="${builder_repository}:${git_sha}")
    assert publisher =~ "docker buildx imagetools inspect"
    assert publisher =~ ~s(--format '{{json .Manifest}}')
    assert publisher =~ "verify_platform"
    assert publisher =~ "/app/_build/prod/lib/openagents/ebin"
    refute publisher =~ "/app/_build/prod/lib/openagents-*/ebin"
    assert publisher =~ "openagents.staging-candidate.v1"
    assert publisher =~ "candidate-manifest.sha256"
    refute publisher =~ ":latest"
    assert sbom =~ "*@sha256:"
  end

  test "relup proof paths propagate worktree admission failures" do
    common = File.read!("ops/relup-proof/common.sh")

    assert common =~ "key=$(proof_key) || return $?"
    assert common =~ ~s|$repo_root/.git/openagents/relup-proof/$key|
    refute common =~ ~s|$repo_root/.git/openagents/relup-proof/$(proof_key)|
  end
end
