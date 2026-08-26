# Delete a repository

You can permanently delete a repository you own from the website, REST API,
or CLI. Maintainers, contributors, and viewers cannot delete a repository.

Deletion removes the Git history, issues, projects, labels, milestones,
memberships, import receipt, and provisioning records. You cannot undo it.

## Delete from the website

1. Open the repository.
2. Find **Delete repository** near the bottom of the **Code** page.
3. Type the full `OWNER/REPOSITORY` name shown in the confirmation field.
4. Select **Delete repository**.

If provisioning is actively writing repository data, OpenAgents asks you to
try again after that operation finishes.

## Delete with the CLI

Pass `--yes` as explicit confirmation:

```sh
openagents repo delete OWNER/REPOSITORY --yes
```

The command also supports `--repo OWNER/REPOSITORY`. When you omit the name,
the CLI infers it from an exact OpenAgents `origin` remote.

## Delete with the REST API

Send an API token with the `forge:write` scope:

```sh
curl --request DELETE \
  --header "Authorization: Bearer $OPENAGENTS_TOKEN" \
  https://openagents.com/api/v1/repos/OWNER/REPOSITORY
```

Success returns `204 No Content`. OpenAgents returns `404 Not Found` when the
repository does not exist or you are not its owner.
