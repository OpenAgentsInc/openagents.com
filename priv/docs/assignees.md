# Assignees

An assignee is the person responsible for an issue. See
`/:owner/:repo/assignees`.

## Assigning

An issue may have more than one assignee. Assigning does not notify anyone
today; there is no notification system yet.

## Unassigning

Removing an assignee leaves no trace on the issue. If you need the history, say
so in a comment.

## A current limitation

The assignable-users endpoint returns an empty list, so no user is reported as
assignable even though assignment itself accepts any login. This is a known gap
rather than a permission rule.
