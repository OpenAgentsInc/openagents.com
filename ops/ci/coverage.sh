#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
coverage_dir="$repo_root/cover"

if [ ! -d "$repo_root/.git" ]; then
  echo "coverage gate must run from a Git worktree" >&2
  exit 1
fi

case "$coverage_dir" in
  "$repo_root/cover") ;;
  *)
    echo "refusing to clean an unexpected coverage path" >&2
    exit 1
    ;;
esac

# Coverage exports are cumulative. Remove the generated directory before both
# runs so an old partition cannot make the current report look better.
rm -rf -- "$coverage_dir"

cd "$repo_root"

MIX_ENV=test mix test --warnings-as-errors --cover --export-coverage default
MIX_ENV=test mix test --warnings-as-errors --only cluster --cover --export-coverage cluster
MIX_ENV=test mix test.coverage
