# Project boards

A project is a board of issues. Browse them at `/:owner/:repo/projects`.

## The description

A project carries one `description` field, which is Markdown. Use it for the
context that applies to the whole project: why the project exists, the
assumptions it operates under, and the decisions that outlive any single issue.
The board renders the description above the columns. Members with write access
to the repository edit it in place.

## Discussion and activity

A project also carries notes, which the board shows below the columns:

- A **discussion note** is Markdown prose you write. Its author can edit or
  delete it; nobody else can, even with write access to the repository.
- An **activity entry** records a change to the project's title, description,
  state, archive standing, or fields. Entries are written when the change
  commits, and they never change or delete.

Issue comments stay on the issue. Project notes carry what applies across
issues.

## The board

The board renders the project's stored fields. Its columns are the options of
the project's **Status** field, in the order that field declares them, and a
project that has declared no field falls back to **To Do**, **In Progress**, and
**Done**.

An item stores an option's identifier, not its label, so relabelling an option
renames the column heading and leaves every card in it. A card whose stored
option the field no longer offers is stale rather than missing, so it appears in
a **No status** column, which the board shows only while something is in it.

Adding an issue to a project creates an item that points at it — the issue
itself is unchanged, so the same issue can sit on several boards, and each board
keeps its own field values for it. Adding an issue a board already carries gives
you back the item it already has rather than a second one.

Members with write access move and remove cards from the card itself. **Move
left** and **Move right** change the column, **Move up** and **Move down** change
the rank within it, and **Remove** takes the card off the board. They are
buttons, so the keyboard and a screen reader reach them the same way a pointer
does. Removing a card removes the item and leaves the issue alone.

## Fields

A project carries fields beyond status. Field values live on the item, not the
issue, so two boards can hold different views of the same work.

A field declares a name, unique within the project, and a data type: `text`,
`number`, `date`, or `single_select`. A single select also declares its options.
An option is either a name, where the name identifies it, or an object with an
`id` and a `name`, where the identifier survives a relabel. Items store the
identifier, so renaming the label never rewrites the items that chose it.

## Through the API

Projects are exposed under `/repos/:owner/:repo/projectsV2`. The repository in
the path controls visibility and write authority for every project, item, field,
and note operation. See [REST API](/docs/rest-api), or use
[`openagents api`](/docs/cli-api) to work with projects from a terminal.

A project object carries `description`, `archived`, `archived_at`, `created_at`,
and `updated_at` alongside its `number`, `title`, `owner`, and `state`. `PATCH`
on a project accepts `title`, `description`, `state`, and `archived`, where
`state` is `open` or `closed` and `archived` is a boolean.

Closing and archiving are different things. A closed project says the work the
board tracked reached an end. An archived project says the board left the
working set, whatever became of the work. Archiving is reversible, and the
project list leaves archived projects out until you pass `archived=true`.

Deleting a project needs the project archived first. The board pairs its delete
control with a confirmation prompt, and an API caller has no prompt, so
archiving is the deliberate step that stands in for one. Deleting removes the
project's fields and items. The issues those items referenced are untouched.

`DELETE` on `/items/:item_id` removes an item. `POST` on `/items/:item_id/move`
moves one, and its body carries `values`, merged the way `PATCH` merges them,
and `position`, a one-based rank within the destination column. A body with only
`position` reorders within the current column. Positions stay dense after every
move, so two moves onto the same rank settle to one order and neither loses a
card.

`PATCH` and `DELETE` on `/fields/:field_id` change and remove fields. Renaming a
field carries its values with it, because the field name is the key each item
stores its value under. A field's data type never changes, an option items still
carry cannot be dropped, and a field items still carry cannot be deleted.

Notes are a separate paginated read at
`/repos/:owner/:repo/projectsV2/:project_number/notes`, so a long-lived board
does not carry an unbounded timeline inside the project object. The response
carries `notes`, `page`, `per_page`, and `total_count`. Each note carries a
stable `id`, its `kind` (`note` or `activity`), the Markdown `body`, the
`author`, `created_at`, and `updated_at`. Pass `kind=note` or `kind=activity` to
read one side of the feed.
