# Commits

`/:repo/commit/:sha` shows one commit: its message, its author, and the files
it changed.

## What a commit page shows

The changed-file list and each file's diff, both bounded. A commit touching
hundreds of files shows the list and truncates the diffs.

## Trailers

Commits carry trailers identifying the agent session that produced them, where
one did. This is what lets a change be traced from the [changelog](/changelog)
back to the conversation that caused it.

## Deploy history

Where a commit reached the fleet, its receipt chain is visible from the
changelog: pushed, built, deployed, and how long each step took.
