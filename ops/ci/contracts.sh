#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

cd "$repo_root"

ops/ci/reference-check.sh
sh -n rel/overlays/bin/migration-lineage
sh -n ops/production/preflight.sh
sh -n ops/staging/cleanup-run.sh
sh -n ops/staging/finalize-report.sh
sh -n ops/staging/new-report.sh
sh -n ops/staging/new-resilience-report.sh
sh -n ops/staging/publish-candidate.sh
sh -n ops/staging/record-result.sh
sh -n ops/staging/regression.sh
sh -n ops/staging/resilience.sh
sh -n ops/staging/run-public-smoke.sh
sh -n ops/staging/scan-evidence.sh
sh -n ops/staging/validate-resilience-report.sh
sh -n ops/staging/validate-report.sh
elixir ops/ci/docs-check.exs
MIX_ENV=test mix test --warnings-as-errors \
  test/openagents/log_safety_test.exs \
  test/openagents/migration_lineage_test.exs \
  test/openagents/runtime_config_test.exs \
  test/openagents/staging_cleanup_test.exs \
  test/openagents/staging_candidate_contract_test.exs \
  test/openagents/staging_regression_contract_test.exs \
  test/openagents/staging_resilience_contract_test.exs \
  test/openagents_web/icon_affordances_test.exs \
  test/openagents_web/icons_test.exs \
  test/openagents_web/ui_test.exs
