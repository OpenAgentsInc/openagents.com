defmodule OpenAgents.Forge.Targets do
  @moduledoc """
  Fleet-target promotion: which pushed commit the fleet should be running.

  Promotion is an operator action — the human approval seam of the deploy
  pipeline (roadmap P2). Targets are append-only rows; the newest row per
  repo is the current target, so "pin back to a known-good SHA" is just
  another promotion, receipted like any other. Status advances through the
  deploy lane (`promoted → building → built → deploying →
  live | failed | reverted | needs_rolling_replace`) with bounded details
  at every step; the `forge:target` broadcast is what wakes the builder.
  """

  import Ecto.Query

  alias OpenAgents.Forge.Target
  alias OpenAgents.Repo

  @statuses ~w(promoted building built deploying live failed reverted needs_rolling_replace)

  @doc "All target statuses, in lifecycle order."
  def statuses, do: @statuses

  @doc """
  Promote a pushed commit as the fleet target for `repo`. `operator` is the
  promoting identity (immutable operator id or a test principal).

  `commit_store` is an optional `{repo, sha} -> :ok | :error | {:error, reason}`
  function that enforces the "only pushed commits are promotable" rule. In test
  it defaults to `:ok`, so tests can exercise promotion without cloning.
  """
  def promote(repo, sha, operator, opts \\ [])
      when is_binary(repo) and is_binary(sha) and is_list(opts) do
    commit_store = Keyword.get(opts, :commit_store, &default_commit_store/2)
    details = Keyword.get(opts, :details, %{}) || %{}

    with :ok <- with_commit_store(repo, sha, commit_store) do
      %Target{}
      |> Target.changeset(%{
        repo: repo,
        sha: sha,
        promoted_by: operator,
        status: "promoted",
        details: details
      })
      |> Repo.insert()
      |> case do
        {:ok, target} ->
          broadcast_promotion(target)
          {:ok, target}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, {:invalid, changeset}}
      end
    end
  end

  @doc "Alias for the current target for a repo."
  def latest(repo), do: current(repo)

  @doc "Alias for `advance/2` with no step details."
  def transition(target_id, status), do: advance(target_id, status, %{})

  @doc "The newest target for `repo` (the current fleet target), or nil."
  def current(repo) do
    Target
    |> where([t], t.repo == ^repo)
    |> order_by([t], desc: t.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Recent targets for a repo, newest first, bounded."
  def recent(repo, limit \\ 10) do
    Target
    |> where([t], t.repo == ^repo)
    |> order_by([t], desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # The deploy lane's transition table doubles as its cluster-wide
  # single-writer arbiter: every node's Builder/HotLoader reacts to the same
  # broadcast, but only the first to win a legal transition (inside
  # `:global.trans`) proceeds; the rest see {:error, {:invalid_transition,..}}
  # and skip. Terminal states accept nothing.
  @transitions %{
    "promoted" => ~w(building failed),
    "building" => ~w(built failed),
    "built" => ~w(deploying needs_rolling_replace failed),
    "deploying" => ~w(live reverted needs_rolling_replace failed)
  }

  @doc """
  Advance a target's deploy status with bounded details — only along the
  legal transition table, atomically (the read-check-update runs inside a
  cluster-wide `:global.trans` on the target id).
  """
  def advance(target_id, status, details \\ %{}) when status in @statuses do
    result =
      :global.trans({{:forge_target_advance, target_id}, self()}, fn ->
        case Repo.get(Target, target_id) do
          nil ->
            {:error, :not_found}

          %Target{status: current} = target ->
            allowed = Map.get(@transitions, current, [])

            cond do
              allowed == [] ->
                {:error, {:terminal, current}}

              status in allowed ->
                target
                |> Target.status_changeset(status, bounded_details(details))
                |> Repo.update()

              true ->
                {:error, {:invalid_transition, current, status}}
            end
        end
      end)

    with {:ok, target} <- result do
      broadcast_status(target)
      {:ok, target}
    end
  end

  defp bounded_details(details) do
    details
    |> Enum.map(fn {key, value} -> {to_string(key), bound_value(value)} end)
    |> Map.new()
  end

  defp bound_value(value) when is_binary(value), do: String.slice(value, 0, 8_192)
  defp bound_value(value) when is_list(value), do: Enum.take(value, 100)
  defp bound_value(value), do: value

  defp with_commit_store(repo, sha, store) do
    case store.(repo, sha) do
      :ok -> :ok
      :error -> {:error, :unknown_sha}
      {:error, reason} -> {:error, reason}
    end
  end

  # In test we skip the WAL-backed repo check so unit tests can exercise the
  # lifecycle without cloning. In dev/prod we verify the commit exists in the
  # bare repo before allowing promotion.
  defp default_commit_store(repo, sha) do
    if function_exported?(Mix, :env, 0) and Mix.env() == :test do
      :ok
    else
      validate_git_commit(repo, sha)
    end
  end

  defp validate_git_commit(repo, sha) do
    cond do
      not Regex.match?(~r/^[0-9a-f]{7,40}$/, sha) ->
        {:error, :invalid_sha}

      not commit_exists?(repo, sha) ->
        {:error, :unknown_sha}

      true ->
        :ok
    end
  end

  defp commit_exists?(repo, sha) do
    OpenAgents.Forge.Sync.ensure_fresh(repo)
    path = OpenAgents.Forge.Repos.bare_path(repo)

    case OpenAgents.Forge.Repos.git(path, ["cat-file", "-e", sha <> "^{commit}"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp broadcast_promotion(%Target{} = target) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "forge:target",
      {:forge_target, %{repo: target.repo, sha: target.sha, target_id: target.id}}
    )
  end

  # Every successful status advance is announced (additive to the settled
  # contract, flagged on #126): the public status page renders the pipeline
  # sweeping promoted→building→built→deploying→live as it happens.
  defp broadcast_status(%Target{} = target) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "forge:target",
      {:forge_target_status,
       %{repo: target.repo, sha: target.sha, target_id: target.id, status: target.status}}
    )
  end
end
