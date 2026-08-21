# Browsing code

Open a repository that you can access at `/:owner/:repo`. Start from
[Repositories](/repositories) when you do not know the exact path.

## Files

`/:owner/:repo/blob/:ref/*path` renders one file at one ref. The ref is part of
the URL, so a file link stays at that revision when the branch moves.

The repository page also lists branches, tags, recent commits, and the clone
URL. Use the [CLI and Git guide](/docs/clone-push-pull) to clone or change the
repository.

## What is public

Repositories are served at a disclosure level, not simply public or private. A
repository may expose its history and metadata while serving only an allow-list
of file paths. A path outside that list is not found rather than forbidden —
the distinction between "no such file" and "you may not see this file" is
itself a disclosure.

## Size limits

Rendering is bounded. Very large files and very large diffs are truncated
rather than streamed in full.
