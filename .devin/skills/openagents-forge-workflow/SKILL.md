---
name: openagents-forge-workflow
description: OpenAgents forge workflow for Devin sessions working on openagents.com issues.
allowed-tools:
  - read
  - exec
  - grep
---

Use this skill when a user asks you to work on an OpenAgents issue in the
`OpenAgentsInc/openagents.com` repository. This skill is a supplement to
`.agents/skills/openagents-work-management/SKILL.md`; read that skill first.

## Before you start

1. Read `.agents/skills/openagents-work-management/SKILL.md`.
2. Read the issue assigned to you. Use the OpenAgents CLI if it is available, or
   read the issue from the web URL.
3. Clone the repository and set the forge remote:
   ```sh
   git clone https://openagents.com/OpenAgentsInc/openagents.com.git /home/ubuntu/repos/openagents.com
   cd /home/ubuntu/repos/openagents.com
   git remote -v
   ```
4. Authenticate the OpenAgents CLI. Cloud Devin machines do not have an OS
   credential store, so `openagents auth login --token-stdin` fails. Use the
   `OPENAGENTS_TOKEN` environment variable instead:
   ```sh
   OPENAGENTS_TOKEN=$OPENAGENTS_TOKEN openagents api repos/OpenAgentsInc/openagents.com/issues/<NUMBER>
   ```
   If `OPENAGENTS_TOKEN` is not set, find the token with
   `env | grep -iE 'openagents|token'` and use the variable that is set. Do not
   print or commit tokens.

## Working

- Implement only the assigned issue. Do not work on unrelated issues.
- Run `mix precommit` before you consider the work complete. If the same
  failures also fail on a pristine checkout, note them in your report and
  continue.
- Use the OpenAgents CLI to add a completion comment and close the issue when
  the change is on main:
  ```sh
  OPENAGENTS_TOKEN=$OPENAGENTS_TOKEN openagents api -X POST \
    -f body="Fixed in <branch-or-commit>." \
    repos/OpenAgentsInc/openagents.com/issues/<NUMBER>/comments
  ```
  ```sh
  printf '%s' '{"state":"closed","state_reason":"completed"}' | \
    OPENAGENTS_TOKEN=$OPENAGENTS_TOKEN openagents api -X PATCH --input - \
    repos/OpenAgentsInc/openagents.com/issues/<NUMBER>
  ```

## Push to main

This repository does not use pull requests. Do not wait for the user to merge.

- If your work is on a `devin/...` branch and the branch is fast-forwardable,
  merge it into `main` and push to the forge:
  ```sh
  git checkout main
  git merge --ff-only <your-branch>
  git push openagents main
  ```
- If the `openagents` remote does not exist and `origin` points to
  `openagents.com`, use `git push origin main` instead.
- Do not push to the GitHub mirror (`github.com`).

## Rules

- Do not print or commit the `OPENAGENTS_TOKEN`.
- Do not push to `origin` if `origin` points to GitHub.
- Do not wait for the user to merge; do it yourself.
- If you are stuck on the clone, setup, or token, say so and stop before
  editing code.
