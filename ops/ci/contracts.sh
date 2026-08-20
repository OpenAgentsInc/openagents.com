#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

cd "$repo_root"

ops/ci/reference-check.sh
sh -n ops/staging/cleanup-run.sh
elixir ops/ci/docs-check.exs
MIX_ENV=test mix test --warnings-as-errors \
  test/openagents/log_safety_test.exs \
  test/openagents/runtime_config_test.exs \
  test/openagents/staging_cleanup_test.exs \
  test/openagents_web/icon_affordances_test.exs \
  test/openagents_web/icons_test.exs \
  test/openagents_web/ui_test.exs
