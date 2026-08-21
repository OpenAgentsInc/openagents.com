defmodule OpenAgents.Forge do
  @moduledoc """
  Sarah's own git forge — the public API of the bounded context (audit A6).

  This app serves the forge at `openagents.com/<owner>/<repo>.git` via stock Git
  smart-HTTP (`OpenAgents.Forge.GitHTTP`), with the WAL in object storage as ref
  truth (`OpenAgents.Forge.WAL`, Continuity-shaped per audit A7), bare repos on
  the stateful partition as per-node cache (`OpenAgents.Forge.Repos` /
  `OpenAgents.Forge.Sync`), pushes acked only after WAL persist
  (`OpenAgents.Forge.Pushes`), and Postgres holding derived receipts only.

  Hard edges: no imports from conversation contexts; emits receipts and
  PubSub (`forge:pushes`), never reads turns/memory/voice.
  """

  import Ecto.Query

  alias OpenAgents.Forge.PushReceipt
  alias OpenAgents.Repo

  @doc "Whether the forge endpoint is enabled (default true; env-gated in prod)."
  def enabled? do
    Application.get_env(:openagents, :forge_enabled, true)
  end

  @doc "Recent push receipts for one repo, newest first, bounded."
  def recent_pushes(repo, limit \\ 20) do
    PushReceipt
    |> where([p], p.repo == ^repo)
    |> order_by([p], desc: p.wal_seq)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Recent deploy receipts for one repo, newest first, bounded."
  def recent_deploys(repo, limit \\ 20) do
    OpenAgents.Forge.DeployReceipt
    |> where([d], d.repo == ^repo)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Recent build receipts for one repo, newest first, bounded."
  def recent_builds(repo, limit \\ 20) do
    OpenAgents.Forge.BuildReceipt
    |> where([b], b.repo == ^repo)
    |> order_by([b], desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Every receipt in the chain that references `sha` (full or abbreviated,
  ≥7 chars): the commit's deploy story for the public commit view (#137).
  Bounded scans; a sha older than the scan window honestly returns empty.
  """
  def receipts_for(repo, sha) do
    %{
      pushes:
        repo
        |> recent_pushes(200)
        |> Enum.filter(fn push ->
          push.refs
          |> Map.values()
          |> Enum.any?(fn
            %{"new" => new} -> sha_match?(sha, new)
            new when is_binary(new) -> sha_match?(sha, new)
            _ -> false
          end)
        end),
      builds: repo |> recent_builds(200) |> Enum.filter(&sha_match?(sha, &1.sha)),
      targets:
        repo |> OpenAgents.Forge.Targets.recent(100) |> Enum.filter(&sha_match?(sha, &1.sha)),
      deploys: repo |> recent_deploys(200) |> Enum.filter(&sha_match?(sha, &1.sha))
    }
  end

  @doc "Prefix-match two shas in either direction (short vs full), ≥7 chars."
  def sha_match?(a, b) when is_binary(a) and is_binary(b) do
    min(byte_size(a), byte_size(b)) >= 7 and
      (String.starts_with?(a, b) or String.starts_with?(b, a))
  end

  def sha_match?(_a, _b), do: false

  @doc "The clone URL for a repo on this deployment."
  def clone_url(repo) do
    OpenAgentsWeb.Endpoint.url() <> "/OpenAgentsInc/#{repo}.git"
  end
end
