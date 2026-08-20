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
  alias OpenAgents.Forge.DeployReceipt
  alias OpenAgents.Repo

  @statuses ~w(promoted building built deploying live failed reverted needs_rolling_replace)

  @doc "All target statuses, in lifecycle order."
  def statuses, do: @statuses

  @doc """
  Promote a pushed commit as the fleet target for `repo`. `operator` is the
  promoting identity (immutable operator id or a test principal).

  Verifies the SHA is actually in the WAL-backed repo — only pushed commits
  are ever promotable (SELF-EDIT precondition, enforced from day one).

  `commit_store` is an optional `{repo, sha} -> :ok | :error | {:error, reason}`
  function that decides *existence*. It defaults to the real WAL-backed repo
  check in every environment, test included: an env-dependent bypass would
  mean the precondition is never actually exercised. The SHA *format* check
  is not part of the store and always runs, so an injected store can never
  widen what a well-formed SHA is.
  """
  def promote(repo, sha, operator, opts \\ [])
      when is_binary(repo) and is_binary(sha) and is_list(opts) do
    commit_store = Keyword.get(opts, :commit_store, &commit_exists_store/2)
    details = Keyword.get(opts, :details, %{}) || %{}

    with :ok <- validate_sha_format(sha),
         :ok <- with_commit_store(repo, sha, commit_store) do
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
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "The newest immutable live target for `repo`, or nil."
  def live(repo) do
    Target
    |> where([t], t.repo == ^repo and t.status == "live")
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Newest immutable live targets for `repo`, bounded and newest first."
  def live_history(repo, limit \\ 2) do
    Target
    |> where([t], t.repo == ^repo and t.status == "live")
    |> order_by([t], desc: t.updated_at, desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Resolve the durable authority for one committed node token."
  def deployment_authority(target_id, deployment_id, artifact_digest) do
    case Repo.get(Target, target_id) do
      %Target{
        status: "live",
        details: %{
          "deployment_id" => ^deployment_id,
          "artifact_digest" => ^artifact_digest
        }
      } ->
        :candidate_live

      %Target{status: "deploying"} ->
        :pending

      %Target{} ->
        :candidate_not_live

      nil ->
        :candidate_not_live
    end
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
            if status in Map.get(@transitions, current, []) do
              target
              |> Target.status_changeset(status, bounded_details(details))
              |> Repo.update()
            else
              {:error, {:invalid_transition, current, status}}
            end
        end
      end)

    with {:ok, target} <- result do
      broadcast_status(target)
      {:ok, target}
    end
  end

  @doc "Fence deployment ownership to the newest promoted target."
  def begin_deployment(target_id) do
    result =
      :global.trans({{:forge_target_deploy, target_id}, self()}, fn ->
        Repo.transaction(fn ->
          target = Repo.get(Target, target_id, lock: "FOR UPDATE") || Repo.rollback(:not_found)

          current_id =
            Target
            |> where([t], t.repo == ^target.repo)
            |> order_by([t], desc: t.inserted_at)
            |> limit(1)
            |> select([t], t.id)
            |> Repo.one()

          if current_id != target.id, do: Repo.rollback(:superseded_target)

          unless target.status == "built" do
            Repo.rollback({:invalid_transition, target.status, "deploying"})
          end

          target
          |> Target.status_changeset("deploying", %{})
          |> Repo.update!()
        end)
      end)

    with {:ok, target} <- result do
      broadcast_status(target)
      {:ok, target}
    end
  end

  @doc "Atomically write a terminal deployment receipt and target status."
  def finish_deployment(target_id, status, details, receipt_attrs)
      when status in ~w(live reverted failed) and is_map(details) and is_map(receipt_attrs) do
    result =
      :global.trans({{:forge_target_deploy, target_id}, self()}, fn ->
        Repo.transaction(fn ->
          target = Repo.get(Target, target_id, lock: "FOR UPDATE") || Repo.rollback(:not_found)

          unless target.status == "deploying" do
            Repo.rollback({:invalid_transition, target.status, status})
          end

          target =
            target
            |> Target.status_changeset(status, bounded_details(details))
            |> Repo.update!()

          receipt_attrs =
            receipt_attrs
            |> Map.put(:target_id, target.id)
            |> Map.put(:repo, target.repo)
            |> Map.put(:sha, target.sha)
            |> Map.put(:result, status)

          receipt =
            %DeployReceipt{}
            |> DeployReceipt.changeset(receipt_attrs)
            |> Repo.insert()
            |> case do
              {:ok, receipt} -> receipt
              {:error, changeset} -> Repo.rollback({:invalid_receipt, changeset})
            end

          %{target: target, receipt: receipt}
        end)
      end)

    with {:ok, %{target: target} = committed} <- result do
      broadcast_status(target)
      {:ok, committed}
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

  defp validate_sha_format(sha) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, sha), do: :ok, else: {:error, :invalid_sha}
  end

  # The promotable set is exactly what the WAL-backed repo contains.
  defp commit_exists_store(repo, sha) do
    if commit_exists?(repo, sha), do: :ok, else: {:error, :unknown_sha}
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
