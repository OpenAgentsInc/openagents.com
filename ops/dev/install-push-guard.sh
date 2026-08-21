#!/bin/sh
set -eu

# Installs the forge-only push guard into this clone.
#
# `ops/ci/push-remote-check.sh` is the guard itself, and `.githooks/pre-push`
# already runs it -- but `.githooks` binds only where `core.hooksPath` points
# at it, and that also turns on the full release gate for every push. This
# installs the guard alone, at Git's default hook path, so a clone refuses a
# push to GitHub without also demanding a release-gate receipt.
#
# Hooks live in the common directory, so one install covers every worktree of
# this clone.
#
#   sh ops/dev/install-push-guard.sh            # install, refusing to clobber
#   sh ops/dev/install-push-guard.sh --force    # replace a foreign pre-push
#   sh ops/dev/install-push-guard.sh --ensure   # `mix precommit` calls this
#
# `--ensure` is the automatic path. Anyone who runs `mix precommit` before
# pushing ends up guarded without having read a word of this, which is the
# only version of a policy that survives contact with a fresh worktree. It
# never fails the build: a machine that has chosen `core.hooksPath`, or that
# keeps its own pre-push hook, has made a decision this script will not
# overrule.
#
# The guard is copied next to the hook rather than run from the worktree. A
# worktree can sit on a branch older than the guard, or on one that never had
# it, and a hook that execs a missing file refuses every push -- including the
# ones to the forge -- with a confusing error.

mode=${1:-}

repo_root=$(git rev-parse --show-toplevel)
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd)
hook_path="$common_dir/hooks/pre-push"
guard_path="$common_dir/hooks/openagents-push-remote-check.sh"
marker='openagents-push-guard'

note() {
  if [ "$mode" = "--ensure" ]; then
    echo "$1"
    exit 0
  fi

  echo "$1" >&2
  exit 1
}

configured_path=$(git config --get core.hooksPath || true)

if [ -n "$configured_path" ]; then
  note "core.hooksPath is $configured_path, so Git ignores $hook_path; that path's pre-push decides."
fi

if [ -e "$hook_path" ] && ! grep -q "$marker" "$hook_path" 2>/dev/null && [ "$mode" != "--force" ]; then
  note "$hook_path exists and is not the push guard; re-run with --force to replace it."
fi

mkdir -p "$common_dir/hooks"

cp "$repo_root/ops/ci/push-remote-check.sh" "$guard_path"
chmod +x "$guard_path"

cat >"$hook_path" <<'HOOK'
#!/bin/sh
# openagents-push-guard — installed by ops/dev/install-push-guard.sh
set -eu

common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd)
exec "$common_dir/hooks/openagents-push-remote-check.sh" "$@"
HOOK

chmod +x "$hook_path"

if [ "$mode" != "--ensure" ]; then
  echo "Installed the forge-only push guard at $hook_path"
  echo "It covers every worktree of $repo_root."
fi
