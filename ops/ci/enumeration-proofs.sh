#!/usr/bin/env bash
#
# Run the enumeration proofs that must never be skipped by the Markdown-only
# precommit path.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

echo "enumeration-proofs: running the enumeration suites"

env MIX_ENV=test mix test --warnings-as-errors \
  test/openagents_web/operator_surface_test.exs \
  test/openagents_web/transparency_surface_test.exs \
  test/openagents/hosted_ci_absence_test.exs \
  test/openagents/transparency/work_disclosure_test.exs \
  test/openagents/network_status_test.exs \
  test/openagents/forge/deployment_lane_test.exs \
  test/openagents/capacity_test.exs \
  test/openagents/accounts/token_vault_test.exs \
  test/openagents/machines/token_vault_test.exs \
  test/openagents/providers/persona_boundary_test.exs \
  test/openagents/data_rights/export_inventory_test.exs
