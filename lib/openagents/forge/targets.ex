defmodule OpenAgents.Forge.Targets do
  @moduledoc """
  Target state machine and promotion API.

  Targets are the durable source of truth for the fleet deployment pipeline.
  Promotion verifies the SHA, transitions are guarded by a database advisory
  lock, and every promotion/transition is broadcast on `OpenAgents.PubSub`.
  """

  import Ecto.Query

  alias OpenAgents.Forge.Target
  alias OpenAgents.Repo

  @advisory_lock_id 99_999_999

  @terminal_statuses ~w(live reverted needs_relup needs_rolling_replace failed)

  @transitions %{
    "promoted" => ["building"],
    "building" => ["built"],
    "built" => ["deploying"],
    "deploying" => ["live", "reverted", "needs_relup", "needs_rolling_replace", "failed"]
  }

  @doc "All valid statuses."
  def valid_statuses, do: Map.keys(@transitions) ++ @terminal_statuses

  @doc """
  Promote a commit to a new fleet target.

  `commit_store` is an arity-2 function that verifies `{repo, sha}` before
  the promotion is persisted. It should return `:ok`, `{:ok, _}` for a known
  SHA, or `:error`/`{:error, _}` for an unknown one.
  """
  @spec promote(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Target.t()} | {:error, atom() | Ecto.Changeset.t()}
  def promote(repo, sha, promoted_by, opts \\ []) do
    commit_store = Keyword.get(opts, :commit_store, &default_commit_store/2)
    details = Keyword.get(opts, :details, %{})

    case commit_store.(repo, sha) do
      :ok -> do_promote(repo, sha, promoted_by, details)
      {:ok, _} -> do_promote(repo, sha, promoted_by, details)
      _ -> {:error, :unknown_sha}
    end
  end

  @doc """
  Advance an existing target's status through the state machine.

  Only one node can advance a target at a time. Terminal targets cannot
  transition out of their terminal state.
  """
  @spec transition(pos_integer(), String.t(), keyword()) ::
          {:ok, Target.t()} | {:error, atom() | Ecto.Changeset.t()}
  def transition(target_id, to_status, opts \\ []) do
    new_details = Keyword.get(opts, :details)

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [@advisory_lock_id])
        target = Repo.get!(Target, target_id)

        if terminal?(target.status) do
          Repo.rollback({:terminal, target.status})
        end

        if not valid_transition?(target.status, to_status) do
          Repo.rollback({:invalid_transition, target.status, to_status})
        end

        attrs = %{status: to_status}
        attrs = if new_details, do: Map.put(attrs, :details, new_details), else: attrs

        target
        |> Target.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback({:invalid, changeset})
        end
      end)

    with {:ok, target} <- result do
      broadcast(target)
      {:ok, target}
    end
  end

  @doc "Fetch a target by ID."
  @spec get(pos_integer()) :: Target.t() | nil
  def get(id), do: Repo.get(Target, id)

  @doc "Fetch the most recently promoted target for a repository."
  @spec latest(String.t()) :: Target.t() | nil
  def latest(repo) do
    Target
    |> where([t], t.repo == ^repo)
    |> order_by([t], desc: t.inserted_at, desc: t.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Whether the status is terminal."
  @spec terminal?(String.t()) :: boolean()
  def terminal?(status), do: status in @terminal_statuses

  @doc "Whether `to` is a valid transition from `from`."
  @spec valid_transition?(String.t(), String.t()) :: boolean()
  def valid_transition?(from, to) do
    case Map.fetch(@transitions, from) do
      {:ok, to_statuses} -> to in to_statuses
      :error -> false
    end
  end

  defp do_promote(repo, sha, promoted_by, details) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [@advisory_lock_id])

        %Target{}
        |> Target.changeset(%{
          repo: repo,
          sha: sha,
          promoted_by: promoted_by,
          status: "promoted",
          details: details
        })
        |> Repo.insert()
        |> case do
          {:ok, target} -> target
          {:error, changeset} -> Repo.rollback({:invalid, changeset})
        end
      end)

    with {:ok, target} <- result do
      broadcast(target)
      {:ok, target}
    end
  end

  defp default_commit_store(_repo, _sha), do: {:ok, nil}

  defp broadcast(target) do
    if Process.whereis(OpenAgents.PubSub) do
      Phoenix.PubSub.broadcast(
        OpenAgents.PubSub,
        "forge:targets",
        {:forge_target, target}
      )
    end

    :ok
  end
end
