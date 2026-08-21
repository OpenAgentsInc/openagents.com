#!/bin/sh
set -eu

# Refuses a push to anything but the OpenAgents forge.
#
# The forge is the authority for this repository. It records every push in the
# durable WAL, and it mirrors `main` to GitHub itself
# (`OpenAgents.Forge.Pushes.mirror_now/1`, watched by
# `OpenAgents.Forge.MirrorWatch`). A push sent straight to GitHub arrives
# behind the forge's back: the WAL never sees those objects, the mirror watch
# compares the forge against a mirror that is now ahead of it, and the
# divergence stays invisible until a clone disagrees with the site.
#
# Git hands a pre-push hook the remote's name and URL on argv. Called directly,
# take the same two arguments; a name alone is resolved through `git remote`.

remote_name=${1:-}
remote_url=${2:-}

if [ -z "$remote_url" ] && [ -n "$remote_name" ]; then
  remote_url=$(git remote get-url "$remote_name" 2>/dev/null || printf '%s' "$remote_name")
fi

case "$remote_url" in
  https://openagents.com/* | https://*.openagents.com/* | \
  https://*@openagents.com/* | https://*@*.openagents.com/* | \
  ssh://*openagents.com/* | git@openagents.com:* | git@*.openagents.com:*)
    exit 0
    ;;
esac

# Bounded and loud, for operator-directed recovery: mirroring by hand while the
# forge is down is a real need, and a refusal with no way through invites
# someone to delete the hook instead.
if [ "${OPENAGENTS_ALLOW_NON_FORGE_PUSH:-}" = "1" ]; then
  echo "push_remote_override remote=${remote_name:-unnamed} url=$remote_url" >&2
  exit 0
fi

cat >&2 <<MESSAGE
Refusing to push to ${remote_name:-this remote} ($remote_url).

Pushes go to the OpenAgents forge, which records them in the WAL and mirrors
main to GitHub itself. Pushing to GitHub directly leaves the forge behind its
own mirror.

  git push openagents HEAD:main

Set OPENAGENTS_ALLOW_NON_FORGE_PUSH=1 for operator-directed recovery only.
MESSAGE

exit 1
