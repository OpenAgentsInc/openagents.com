#!/bin/bash
set -eu

# Foundation relup proof: build the current release and show that the release
# artifacts are produced. Full live code_change/3 proofs are left to the
# version-chain and kill-during-install drills once multiple release versions
# are built.

cd "$(dirname "$0")/../.."

echo "=== Building OpenAgents release ==="
rm -rf _build/prod/rel/openagents
MIX_ENV=prod mix do deps.get, compile, assets.deploy, release

echo "=== Verifying release tar ==="
ls -l _build/prod/rel/openagents/releases/*/openagents.tar.gz

echo "=== Relup foundation is in place ==="
