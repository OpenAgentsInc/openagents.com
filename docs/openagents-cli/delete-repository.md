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

## Delete with the CLI

```sh
openagents repo delete OWNER/REPOSITORY --yes
```

You can run the same command through `npx`:

```sh
npx --yes @openagentsinc/cli@latest repo delete OWNER/REPOSITORY --yes
```

## Delete with the REST API

```sh
curl --request DELETE \
  --header "Authorization: Bearer $OPENAGENTS_TOKEN" \
  https://openagents.com/api/v3/repos/OWNER/REPOSITORY
```

Success returns `204 No Content`.
