defmodule OpenAgents.Forge.MirrorWatch do
  @moduledoc """
  Mirror drift detection (#127, RELEASE-004: owned infra, no hosted CI).

  Best-effort mirroring means a failed `--mirror` push only logs — this
  watcher closes the gap. Every tick, for each repo with a configured
  mirror: compare the forge's `main` with the mirror's `main`
  (`git ls-remote`). On divergence it retries the mirror push immediately;
  if the mirror is still behind past the lag threshold, it records one
  `forge_mirror_lagging` degraded incident per lag episode (never a
  per-tick storm) and keeps retrying.

  Freshness is published in `state/0` for the public status page:
  `"off"` (no mirror configured), `"current"`, or `"lagging"` with minutes.
  The mirror URL may embed a credential and never appears in state, logs,
  incidents, or output.
  """

  use GenServer

  require Logger

  alias OpenAgents.Forge.Pushes
  alias OpenAgents.Forge.Repos

  @tick_ms 5 * 60 * 1000
  @lag_threshold_ms 15 * 60 * 1000
  @state_key {__MODULE__, :state}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{lagging_since: %{}, incident_reported: MapSet.new()}}
  end

  @doc "Mirror freshness for the status page: state per configured repo."
  def state do
    :persistent_term.get(@state_key, %{"state" => "off"})
  end

  @impl true
  def handle_info(:tick, state) do
    state = check_all(state)
    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "One check pass over every configured repo. Public for tests."
  def check_all(state, now_ms \\ System.monotonic_time(:millisecond)) do
    configured = Enum.filter(Repos.allowed_repos(), &Pushes.mirror_url/1)

    if configured == [] do
      :persistent_term.put(@state_key, %{"state" => "off"})
      state
    else
      Enum.reduce(configured, state, fn repo, acc -> check_repo(repo, acc, now_ms) end)
    end
  rescue
    error ->
      Logger.warning("forge_mirror_watch_failed code=#{OpenAgents.OperationalLog.code(error)}")
      state
  end

  defp check_repo(repo, state, now_ms) do
    case drift?(repo) do
      :current ->
        publish(repo, "current", nil)

        %{
          state
          | lagging_since: Map.delete(state.lagging_since, repo),
            incident_reported: MapSet.delete(state.incident_reported, repo)
        }

      :behind ->
        # Retry immediately — most lag is one missed best-effort push —
        # and re-check: a healed mirror is current, not lagging.
        _retry = Pushes.mirror_now(repo)

        if drift?(repo) == :current do
          publish(repo, "current", nil)

          %{
            state
            | lagging_since: Map.delete(state.lagging_since, repo),
              incident_reported: MapSet.delete(state.incident_reported, repo)
          }
        else
          since = Map.get(state.lagging_since, repo, now_ms)
          lag_ms = now_ms - since
          publish(repo, "lagging", div(lag_ms, 60_000))
          state = %{state | lagging_since: Map.put(state.lagging_since, repo, since)}

          if lag_ms >= @lag_threshold_ms and repo not in state.incident_reported do
            _incident =
              OpenAgents.Incidents.record(%{
                surface: "job",
                origin: "forge_mirror_watch",
                code: "forge_mirror_lagging",
                severity: "degraded",
                summary: "GitHub mirror for #{repo} behind the forge for #{div(lag_ms, 60_000)}m",
                context: %{"repo" => repo}
              })

            %{state | incident_reported: MapSet.put(state.incident_reported, repo)}
          else
            state
          end
        end

      :unknown ->
        # The mirror host is unreachable (GitHub down): the forge is
        # unaffected by design; keep state, retry next tick, report nothing
        # (the roadmap's acceptance line: pushes still succeed, warning
        # logged).
        state
    end
  end

  # main-ref comparison is the drift signal: the forge's cached main vs the
  # mirror's main. (ls-remote against the configured URL — output discarded
  # except the sha, so the credentialed URL never leaks.)
  defp drift?(repo) do
    with url when is_binary(url) <- Pushes.mirror_url(repo),
         {:ok, forge_main} <- forge_main(repo) do
      case remote_main(url) do
        {:ok, ^forge_main} -> :current
        {:ok, _other_sha} -> :behind
        # A reachable mirror with no main at all (fresh/empty) is behind;
        # only an unreachable host is unknown.
        {:error, :no_remote_main} -> :behind
        {:error, _reason} -> :unknown
      end
    else
      _missing -> :unknown
    end
  end

  defp forge_main(repo) do
    case Repos.refs(repo) do
      %{"refs/heads/main" => sha} when is_binary(sha) -> {:ok, sha}
      _other -> {:error, :no_main}
    end
  end

  defp remote_main(url) do
    case System.cmd(
           "git",
           ["-c", "credential.helper=", "ls-remote", url, "refs/heads/main"],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {output, 0} ->
        case String.split(output) do
          [sha | _rest] when byte_size(sha) == 40 -> {:ok, sha}
          _empty -> {:error, :no_remote_main}
        end

      {_output, _status} ->
        {:error, :remote_unreachable}
    end
  end

  defp publish(repo, mirror_state, lagging_minutes) do
    :persistent_term.put(@state_key, %{
      "state" => mirror_state,
      "repo" => repo,
      "lagging_minutes" => lagging_minutes
    })
  end

  defp schedule, do: Process.send_after(self(), :tick, @tick_ms)
end
