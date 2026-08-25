defmodule OpenAgents.Forge.RepoRef do
  @moduledoc """
  The one place a repository *name* becomes a repository *storage key*.

  Two different strings identify a repository here, and confusing them is what
  issue #190 was:

    * A **name** is what a person has. It is `openagents.com`, or the
      `owner/name` path they clone — `OpenAgentsInc/openagents.com`. It is what
      `OpenAgents.Forge.Repos.allowed_repos/0` lists, what a Git URL carries,
      and what `OpenAgents.Forge.Targets` records on a receipt. A name is not
      unique on its own: two namespaces can each own a repository called
      `docs`.
    * A **storage key** is what the forge keys durable state with. It is
      `Repository.storage_key`, it is unique, it is opaque — a UUID for every
      repository created since `REPOSITORY-001` — and it is the single path
      segment under which the WAL keeps a log
      (`OpenAgents.Forge.WAL`) and a node keeps its bare repository
      (`OpenAgents.Forge.Repos.bare_path/1`).

  Passing a name where a storage key belongs does not fail loudly. Both are
  strings, and a name is a legal path segment, so the forge builds a path out
  of it and finds an empty directory or nothing at all. That is how
  `Verification.verify("openagents.com")` came to report `wal_unreadable` for a
  repository whose log was intact, and how a bare repository under the *name*
  came to sit beside the one under the key.

  ## Resolution order

  `storage_key/1` answers in this order, and the order is the point:

    1. If the string is a legal storage key *and* the WAL holds a log under it,
       it is a storage key and it resolves to itself. This step reaches no
       database, so a verifier handed a key stays independent of PostgreSQL —
       `EXIT-002` — and a repository whose log predates the `repositories`
       table still resolves.
    2. Otherwise the string is treated as a name and looked up in
       `repositories`, by storage key, by `name`, or by the `owner/name` path
       the serving path resolves (`OpenAgents.Forge.GitHTTP`), namespace
       aliases included. Exactly one repository is an answer; two is
       `:ambiguous_name`, because guessing which of two repositories an
       operator meant is worse than saying the name is not enough.
    3. Otherwise `:repository_not_found`.

  A database that cannot be reached during step 2 is `:repository_lookup_unavailable`
  rather than "not found": a name whose answer is unknown must not be reported
  as a name with no answer.
  """

  import Ecto.Query

  alias OpenAgents.Forge.{Repos, WAL}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.{NamespaceAlias, Repository}

  @typedoc "What a person has: a repository `name`, or an `owner/name` path."
  @type name :: String.t()

  @typedoc """
  What the forge keys durable state with: one opaque, unique path segment.
  """
  @type storage_key :: String.t()

  @typedoc "Either of the two, before anyone has decided which it is."
  @type ref :: name() | storage_key()

  @typedoc "Why a reference names no single repository."
  @type resolution_error ::
          :repository_not_found | :ambiguous_name | :repository_lookup_unavailable

  @doc """
  The storage key `ref` names.

  Returns `{:ok, storage_key}`, or `{:error, reason}` where `reason` is one of
  the `t:resolution_error/0` values. See the module documentation for the
  order in which the two interpretations are tried.
  """
  @spec storage_key(term()) :: {:ok, storage_key()} | {:error, resolution_error()}
  def storage_key(ref) when is_binary(ref) do
    if wal_key?(ref) do
      {:ok, ref}
    else
      resolve_name(ref)
    end
  end

  def storage_key(_ref), do: {:error, :repository_not_found}

  @doc """
  The storage key `ref` names, or `ref` itself when nothing settles it.

  For the callers whose honest fallback is the string they were given: a mirror
  push and a cache warm both act on a bare repository that may well be keyed by
  the string itself, and neither is in a position to refuse. A caller that
  reports to a person should use `storage_key/1` instead, so an unresolved name
  is named as one rather than turned into a path.
  """
  @spec storage_key_or_ref(term()) :: term()
  def storage_key_or_ref(ref) when is_binary(ref) do
    case storage_key(ref) do
      {:ok, resolved} -> resolved
      {:error, _reason} -> ref
    end
  end

  def storage_key_or_ref(ref), do: ref

  # A log under this exact key is the only evidence that settles a string as a
  # storage key without asking the database anything.
  defp wal_key?(ref) do
    Repos.valid_storage_key?(ref) and match?({:ok, _generation, _index}, WAL.read_index(ref))
  end

  defp resolve_name(ref) do
    case candidate_keys(ref) do
      [storage_key] -> {:ok, storage_key}
      [] -> {:error, :repository_not_found}
      _two_or_more -> {:error, :ambiguous_name}
    end
  rescue
    _database_unavailable -> {:error, :repository_lookup_unavailable}
  end

  defp candidate_keys(ref) do
    case String.split(ref, "/") do
      [owner, name] -> owner |> path_query(name) |> keys()
      [_bare_name] -> ref |> bare_query() |> keys()
      _not_a_reference -> []
    end
  end

  defp keys(query) do
    query
    |> select([repository], repository.storage_key)
    |> limit(2)
    |> Repo.all()
    |> Enum.uniq()
  end

  # The same mapping the serving path resolves a clone URL through
  # (`OpenAgents.Forge.GitHTTP`), including renamed namespaces, so an operator
  # verifies the repository their `git clone` reached and not a different one.
  defp path_query(owner, name) do
    owner_key = String.downcase(owner)
    name_key = String.downcase(name)

    from repository in Repository,
      join: namespace in assoc(repository, :namespace),
      left_join: namespace_alias in NamespaceAlias,
      on: namespace_alias.namespace_id == namespace.id and namespace_alias.slug_key == ^owner_key,
      where:
        repository.name_key == ^name_key and
          (namespace.slug_key == ^owner_key or not is_nil(namespace_alias.id))
  end

  defp bare_query(ref) do
    name_key = String.downcase(ref)

    from repository in Repository,
      where: repository.storage_key == ^ref or repository.name_key == ^name_key
  end
end
