#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

cd "$repo_root"

MIX_ENV=test mix test --warnings-as-errors \
  test/openagents/stacks_test.exs
