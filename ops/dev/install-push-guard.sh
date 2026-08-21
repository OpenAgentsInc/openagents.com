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
# this clone. Run it once per clone, on every machine.
#
#   sh ops/dev/install-push-guard.sh [--force]

force=${1:-}

repo_root=$(git rev-parse --show-toplevel)
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd)
hook_path="$common_dir/hooks/pre-push"
marker='openagents-push-guard'

configured_path=$(git config --get core.hooksPath || true)

if [ -n "$configured_path" ]; then
  echo "core.hooksPath is set to $configured_path, so Git ignores $hook_path." >&2
  echo "That path's own pre-push hook decides; nothing installed." >&2
  exit 1
fi

if [ -e "$hook_path" ] && ! grep -q "$marker" "$hook_path" 2>/dev/null && [ "$force" != "--force" ]; then
  echo "$hook_path exists and is not the push guard. Re-run with --force to replace it." >&2
  exit 1
fi

mkdir -p "$common_dir/hooks"

cat >"$hook_path" <<'HOOK'
#!/bin/sh
# openagents-push-guard — installed by ops/dev/install-push-guard.sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
exec "$repo_root/ops/ci/push-remote-check.sh" "$@"
HOOK

chmod +x "$hook_path"

echo "Installed the forge-only push guard at $hook_path"
echo "It covers every worktree of $repo_root."
