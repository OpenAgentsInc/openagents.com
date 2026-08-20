defmodule OpenAgents.Forge.Visibility do
  @moduledoc """
  The per-repo public disclosure level (TRANSPARENCY-001, spec §2 in
  `docs/plans/2026-08-19-transparency-spec-and-roadmap.md`): one dial
  governing what the public transparency surfaces may show for a repo.

      :l0  dark    — nothing public (the default for any repo not configured)
      :l1  pulse   — timings and counts only, no shas
      :l2  ledger  — shas, summaries, paths, receipt chain, forge links
      :l3  glass   — full file contents and diffs

  Operator-owned config (`:forge_public_visibility`), never derived from
  request data. Raising a repo's level is a deliberate config change that
  ships through the same receipted pipeline as any other change.
  """

  @levels [:l0, :l1, :l2, :l3]
  @rank %{l0: 0, l1: 1, l2: 2, l3: 3}

  @doc "All levels, lowest first."
  def levels, do: @levels

  @doc "The configured public level for `repo` (`:l0` when unconfigured)."
  def level(repo) when is_binary(repo) do
    :openagents
    |> Application.get_env(:forge_public_visibility, %{})
    |> Map.get(repo, :l0)
  end

  def level(_), do: :l0

  @doc """
  Whether `repo`'s level admits a capability:

    * `:ledger` — commit metadata, changed-file paths, receipt chain (≥ l2)
    * `:files`  — browsing arbitrary blobs/trees, i.e. the source (≥ l3)
    * `:diffs`  — full patch bodies (≥ l3)
  """
  def allows?(repo, capability) do
    minimum =
      case capability do
        :ledger -> :l2
        :files -> :l3
        :diffs -> :l3
      end

    @rank[level(repo)] >= @rank[minimum]
  end

  @doc """
  The explicitly published document paths for `repo` — the allowlist that
  lets a private repository publish a few documents (an audit, a spec, the
  changelog) without making its source browsable.
  """
  def published_paths(repo) when is_binary(repo) do
    :openagents
    |> Application.get_env(:forge_public_paths, %{})
    |> Map.get(repo, [])
  end

  def published_paths(_), do: []

  @doc "Whether `path` is one of `repo`'s published documents."
  def published?(repo, path), do: path in published_paths(repo)

  @doc """
  Whether the blob view may serve `path` at `ref`.

  A repo at `:l3` is fully browsable at any ref. Below that, only an
  explicitly published document is served, and **only at the current
  default-branch head** — otherwise the ref parameter would be a window
  into every past revision of that file, which is exactly what publishing
  one document is not supposed to open up.
  """
  def allows_file?(repo, path, ref_sha, head_sha) do
    cond do
      allows?(repo, :files) -> true
      not published?(repo, path) -> false
      is_binary(ref_sha) and ref_sha == head_sha -> true
      true -> false
    end
  end

  @doc """
  The owning account for `repo` — the first path segment of its public URL,
  so a forge URL is shaped exactly like the GitHub one it replaces
  (`/OpenAgentsInc/sarah/blob/main/README.md`). Operator-owned config.
  """
  def owner(repo) when is_binary(repo) do
    :openagents
    |> Application.get_env(:forge_repo_owners, %{})
    |> Map.get(repo)
  end

  def owner(_), do: nil

  @doc "Whether `owner` is the configured owner of `repo` (case-insensitive)."
  def owns?(owner, repo) when is_binary(owner) and is_binary(repo) do
    case owner(repo) do
      nil -> false
      configured -> String.downcase(configured) == String.downcase(owner)
    end
  end

  def owns?(_owner, _repo), do: false

  @doc "The public URL path for a repo, GitHub-shaped."
  def repo_path(repo) do
    case owner(repo) do
      nil -> nil
      owner -> "/" <> owner <> "/" <> repo
    end
  end
end
