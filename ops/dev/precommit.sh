#!/usr/bin/env bash
#
# The precommit gate, scaled to what changed.
#
# The full gate compiles, audits dependencies, builds assets, and runs the whole
# suite — some four thousand tests and several minutes. That is the right price
# for a change to the application and the wrong one for a change to a document,
# and paying it for prose is how a gate stops being run.
#
# So a change that touches only prose runs only the checks that read prose. The
# rule is deliberately narrow: every changed path must be Markdown, and no
# Markdown that any code or test names by path counts, because several documents
# in this repository are read by the suite and changing one of those is a change
# to the suite's input. Anything else, including anything unreadable or
# ambiguous, takes the full gate.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

full() {
  mix hex.audit
  mix deps.audit
  mix compile --warnings-as-errors
  mix deps.unlock --check-unused
  mix format
  mix cmd ops/ci/reference-check.sh
  mix cmd elixir ops/ci/docs-check.exs
  mix assets.test
  mix test --warnings-as-errors
}

prose() {
  mix format
  mix cmd ops/ci/reference-check.sh
  mix cmd elixir ops/ci/docs-check.exs
}

sh ops/dev/install-push-guard.sh --ensure

# Everything this change touches: the working tree against HEAD, plus anything
# already committed that main has not seen. A commit made before running this
# is still part of what is about to be pushed.
changed=$(
  {
    git diff --name-only HEAD 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
    if git rev-parse --verify --quiet openagents/main >/dev/null 2>&1; then
      git diff --name-only "$(git merge-base HEAD openagents/main)"...HEAD 2>/dev/null || true
    fi
  } | sort -u | sed '/^$/d'
)

# Nothing to classify is not a reason to skip: a gate that finds no evidence
# runs the whole thing.
if [ -z "$changed" ]; then
  full
  exit 0
fi

while IFS= read -r path; do
  case "$path" in
    *.md) ;;
    *)
      full
      exit 0
      ;;
  esac

  # A document the suite reads is the suite's input, whatever its extension.
  if grep -rqlF "$path" lib test ops --include="*.ex" --include="*.exs" --include="*.sh" \
    2>/dev/null; then
    full
    exit 0
  fi
done <<EOF_PATHS
$changed
EOF_PATHS

echo "precommit: prose only (${changed//$'\n'/, }) — running the checks that read prose."
prose
