# Browsing code

Any repository the forge hosts can be read in the browser at `/:repo`.

## Files

`/:repo/blob/:ref/*path` renders one file at one ref. The ref is part of the
URL, so a link to a file is a link to that file *at that revision* and does not
drift as the branch moves.

## What is public

Repositories are served at a disclosure level, not simply public or private. A
repository may expose its history and metadata while serving only an allow-list
of file paths. A path outside that list is not found rather than forbidden —
the distinction between "no such file" and "you may not see this file" is
itself a disclosure.

## Size limits

Rendering is bounded. Very large files and very large diffs are truncated
rather than streamed in full.
