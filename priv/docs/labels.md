# Labels

Labels classify issues. Manage them at `/:owner/:repo/labels`.

## Creating a label

A label has a name, a colour, and an optional description. Names are unique
within a repository.

## Applying labels

Apply them from an issue, or when creating one. An issue may carry any number.

## Deleting a label

Deleting removes it from every issue that carries it. The issues themselves are
untouched.

## Names with spaces

A label named `good first issue` is valid. In a URL its spaces are encoded, so
prefer the API's label endpoints over hand-written URLs when scripting.
