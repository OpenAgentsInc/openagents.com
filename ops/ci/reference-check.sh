#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

allowlist="ops/ci/allowed-sarah-references.txt"
matches=$(mktemp /tmp/openagents-reference-matches.XXXXXX)
patterns=$(mktemp /tmp/openagents-reference-patterns.XXXXXX)
unclassified=$(mktemp /tmp/openagents-reference-unclassified.XXXXXX)

cleanup() {
  unlink "$matches" 2>/dev/null || true
  unlink "$patterns" 2>/dev/null || true
  unlink "$unclassified" 2>/dev/null || true
}

trap cleanup EXIT

# Generic infrastructure names are never valid in active source, tests,
# configuration, or assets. Historical documents are classified separately.
banned_in_active='OpenAgents\.Sarah(\.|$)|Sarah(UI|ConnCase|DataCase|ChannelCase|Factory|Fixtures|ClusterTest|TargetsTest)|sarah_(live_view|html|html_helpers|source_dir|forge)|(^|/)(style-)?sarah\.css|/(var/lib|tmp)/sarah|OpenAgents-Sarah|sarah[-_]builder|sarah[-_]forge|sarah-wal-seq|sarah/job-'

if rg --line-number --no-heading --color never --ignore-case \
  "$banned_in_active" AGENTS.md README.md assets config lib test; then
  echo "Unclassified Sarah infrastructure reference found in active code." >&2
  exit 1
fi

awk 'NF && $1 !~ /^#/' "$allowlist" >"$patterns"

rg --line-number --no-heading --color never --ignore-case \
  --glob '!ops/ci/allowed-sarah-references.txt' \
  --glob '!ops/ci/docs-check.exs' \
  --glob '!ops/ci/reference-check.sh' \
  'sarah|/var/lib/sarah|/tmp/sarah|pro\.openagents\.com|api\.openagents\.com' \
  AGENTS.md INVARIANTS.md README.md assets config docs lib ops test >"$matches" || true

grep --extended-regexp --invert-match --file="$patterns" "$matches" >"$unclassified" || true

if test -s "$unclassified"; then
  echo "Unclassified Sarah or retired-service references:" >&2
  sed -n '1,200p' "$unclassified" >&2
  exit 1
fi

echo "Sarah reference classification passed"
