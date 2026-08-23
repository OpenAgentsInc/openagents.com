defmodule OpenAgents.PostHog do
  @moduledoc """
  Server-side read access to the project's own PostHog analytics.

  The operator analytics surface (`/admin/analytics`) pulls computed results
  from the PostHog REST API with a personal API key. This module is that
  boundary: it owns the HogQL for each bounded question, shapes the rows into
  plain maps, and never raises — a failed or unconfigured integration is an
  ordinary `{:error, reason}`, which the surface renders as a degraded state.

  Configuration (see `config/runtime.exs`):

  - `OPENAGENTS_POSTHOG_PERSONAL_API_KEY` — a `phx_...` personal API key.
    Absent means disabled: no request ever leaves, and the surface says so.
  - `OPENAGENTS_POSTHOG_PROJECT_ID` — the numeric PostHog project id.
  - `OPENAGENTS_POSTHOG_APP_HOST` — optional; defaults to
    `https://us.posthog.com`. This is the app/API host, not the event ingest
    host used by capture.

  The key is read-only analytics material. It grants whatever scopes the key
  was created with and must not be logged or echoed into errors.
  """

  require Logger

  @receive_timeout_ms 8_000

  @type shaped :: map()

  @doc """
  Whether the read path has both credentials configured. Capture being
  enabled does not imply this: the personal API key is a separate setting.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    present?(settings()[:personal_api_key]) and integer_id?(settings()[:project_id])
  end

  @doc """
  Everything the operator analytics page shows.

  Returns `{:ok, shaped}` with six bounded projections, or
  `{:error, :not_configured | :unavailable}`. Each projection runs as its own
  HogQL query; a failure of any one fails the whole pull, because partial
  numbers presented next to each other read as complete.
  """
  @spec overview() :: {:ok, shaped()} | {:error, :not_configured | :unavailable}
  def overview do
    if enabled?() do
      with {:ok, events} <- run(event_counts_sql(), "event_counts"),
           {:ok, funnel} <- run(funnel_sql(), "funnel"),
           {:ok, chat} <- run(chat_turns_sql(), "chat_turns"),
           {:ok, pages} <- run(top_pages_sql(), "top_pages"),
           {:ok, triage} <- run(triage_health_sql(), "triage_health"),
           {:ok, issue_flow} <- run(weekly_issue_flow_sql(), "weekly_issue_flow") do
        {:ok,
         %{
           generated_at: DateTime.utc_now(),
           event_counts: shape_rows(events),
           funnel: shape_rows(funnel) |> List.first(%{}),
           chat_turns: shape_chat_turns(shape_rows(chat) |> List.first(%{})),
           top_pages: shape_rows(pages),
           triage_health: shape_triage_health(shape_rows(triage) |> List.first(%{})),
           weekly_issue_flow: shape_rows(issue_flow)
         }}
      end
    else
      {:error, :not_configured}
    end
  end

  # ── questions ────────────────────────────────────────────────────────────

  defp event_counts_sql do
    """
    SELECT event, count() AS count, uniq(person_id) AS people
    FROM events
    WHERE timestamp >= now() - INTERVAL 1 DAY
    GROUP BY event
    ORDER BY count DESC
    LIMIT 25
    """
    |> squash()
  end

  defp funnel_sql do
    """
    SELECT
      countIf(event = 'auth_started') AS auth_started,
      countIf(event = 'user_signed_up') AS user_signed_up,
      countIf(event = 'user_signed_in') AS user_signed_in,
      uniqIf(person_id, event = 'user_signed_up') AS identified_signups,
      countIf(event = 'chat_message_sent') AS chat_message_sent
    FROM events
    WHERE timestamp >= now() - INTERVAL 1 DAY
    """
    |> squash()
  end

  defp chat_turns_sql do
    """
    SELECT
      count() AS turns,
      countIf(properties.outcome = 'completed') AS completed,
      countIf(properties.outcome = 'failed') AS failed,
      countIf(properties.outcome = 'cancelled') AS cancelled,
      round(avg(properties.duration_ms)) AS avg_duration_ms,
      max(properties.duration_ms) AS max_duration_ms
    FROM events
    WHERE timestamp >= now() - INTERVAL 1 DAY AND event = 'chat_turn_completed'
    """
    |> squash()
  end

  defp top_pages_sql do
    """
    SELECT properties.$current_url AS url, count() AS views
    FROM events
    WHERE timestamp >= now() - INTERVAL 1 DAY AND event = '$pageview'
    GROUP BY properties.$current_url
    ORDER BY views DESC
    LIMIT 8
    """
    |> squash()
  end

  defp triage_health_sql do
    """
    WITH issue_events AS (
      SELECT
        properties.owner AS owner,
        properties.repo AS repo,
        properties.issue_number AS issue_number,
        minIf(timestamp, event = 'issue_created') AS created_at,
        argMax(properties.has_labels, timestamp) AS has_labels,
        argMax(properties.issue_state, timestamp) AS issue_state
      FROM events
      WHERE event IN ('issue_created', 'issue_updated')
        AND timestamp >= now() - INTERVAL 90 DAY
        AND notEmpty(properties.owner)
        AND notEmpty(properties.repo)
        AND properties.issue_number IS NOT NULL
      GROUP BY owner, repo, issue_number
    ),
    first_responses AS (
      SELECT
        properties.owner AS owner,
        properties.repo AS repo,
        properties.issue_number AS issue_number,
        min(timestamp) AS responded_at
      FROM events
      WHERE event = 'issue_commented'
        AND timestamp >= now() - INTERVAL 90 DAY
        AND properties.is_maintainer = true
        AND properties.issue_number IS NOT NULL
      GROUP BY owner, repo, issue_number
    ),
    response_times AS (
      SELECT dateDiff('second', issues.created_at, responses.responded_at) AS seconds
      FROM issue_events AS issues
      INNER JOIN first_responses AS responses
        ON issues.owner = responses.owner
        AND issues.repo = responses.repo
        AND issues.issue_number = responses.issue_number
      WHERE responses.responded_at >= issues.created_at
    ),
    label_health AS (
      SELECT
        countIf(created_at <= now() - INTERVAL 1 DAY AND issue_state = 'open') AS eligible,
        countIf(
          created_at <= now() - INTERVAL 1 DAY
          AND issue_state = 'open'
          AND has_labels = false
        ) AS unlabeled
      FROM issue_events
    )
    SELECT
      round(median(seconds) / 3600, 1) AS median_first_maintainer_response_hours,
      (SELECT eligible FROM label_health) AS eligible_issues,
      (SELECT unlabeled FROM label_health) AS unlabeled_issues,
      if(
        eligible_issues = 0,
        0,
        round(unlabeled_issues * 100.0 / eligible_issues, 1)
      ) AS unlabeled_after_24h_percent
    FROM response_times
    """
    |> squash()
  end

  defp weekly_issue_flow_sql do
    """
    SELECT
      formatDateTime(toStartOfWeek(timestamp), '%Y-%m-%d') AS week,
      countIf(event = 'issue_created') AS created,
      countIf(
        event = 'issue_updated'
        AND properties.issue_state_changed = true
        AND properties.issue_state = 'closed'
      ) AS closed
    FROM events
    WHERE timestamp >= now() - INTERVAL 8 WEEK
      AND event IN ('issue_created', 'issue_updated')
    GROUP BY week
    ORDER BY week ASC
    """
    |> squash()
  end

  # ── shaping ──────────────────────────────────────────────────────────────

  defp shape_rows(%{"results" => results, "columns" => columns}) when is_list(results) do
    keys = Enum.map(columns, &to_string/1)

    Enum.map(results, fn row ->
      keys |> Enum.zip(List.wrap(row)) |> Map.new(fn {k, v} -> {k, scalar(v)} end)
    end)
  end

  defp shape_rows(_unexpected), do: []

  defp shape_chat_turns(row) do
    %{
      "turns" => count_value(row["turns"]),
      "completed" => count_value(row["completed"]),
      "failed" => count_value(row["failed"]),
      "cancelled" => count_value(row["cancelled"]),
      "avg_duration_ms" => duration_value(row["avg_duration_ms"]),
      "max_duration_ms" => duration_value(row["max_duration_ms"])
    }
  end

  defp shape_triage_health(row) do
    %{
      "median_first_maintainer_response_hours" =>
        numeric_or_nil(row["median_first_maintainer_response_hours"]),
      "eligible_issues" => count_value(row["eligible_issues"]),
      "unlabeled_issues" => count_value(row["unlabeled_issues"]),
      "unlabeled_after_24h_percent" => numeric_value(row["unlabeled_after_24h_percent"])
    }
  end

  defp scalar(value) when is_integer(value) or is_float(value), do: value
  defp scalar(value) when is_binary(value), do: value
  defp scalar(nil), do: nil
  defp scalar(value), do: to_string(value)

  # PostHog aggregates arrive as integers or floats depending on the
  # expression; counts round down and durations keep one decimal of sense by
  # staying numeric.
  defp count_value(value) when is_integer(value), do: value
  defp count_value(value) when is_float(value), do: trunc(value)
  defp count_value(_other), do: 0

  defp duration_value(value) when is_integer(value), do: value
  defp duration_value(value) when is_float(value), do: round(value)
  defp duration_value(_other), do: nil

  defp numeric_value(value) when is_integer(value) or is_float(value), do: value
  defp numeric_value(_other), do: 0

  defp numeric_or_nil(value) when is_integer(value) or is_float(value), do: value
  defp numeric_or_nil(_other), do: nil

  # ── transport ────────────────────────────────────────────────────────────

  defp run(sql, label) do
    settings = settings()
    url = "#{settings[:app_host]}/api/projects/#{settings[:project_id]}/query/"

    request_options =
      [
        json: %{query: %{kind: "HogQLQuery", query: sql}},
        auth: {:bearer, settings[:personal_api_key]},
        headers: [{"user-agent", "openagents-admin-analytics"}],
        receive_timeout: @receive_timeout_ms,
        retry: false
      ]
      |> Keyword.merge(settings[:request_options] || [])

    case Req.post(url, request_options) do
      {:ok, %Req.Response{status: 200, body: %{"results" => _} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        Logger.warning("posthog_query_failed label=#{label} code=posthog_key_rejected")
        {:error, :unavailable}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("posthog_query_failed label=#{label} code=posthog_status_#{status}")
        {:error, :unavailable}

      {:error, _transport_error} ->
        Logger.warning("posthog_query_failed label=#{label} code=posthog_unreachable")
        {:error, :unavailable}
    end
  rescue
    error ->
      Logger.warning(
        "posthog_query_failed label=#{label} code=#{OpenAgents.OperationalLog.code(error)}"
      )

      {:error, :unavailable}
  end

  defp settings, do: Application.get_env(:openagents, :posthog_analytics, [])

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp integer_id?(value) when is_integer(value), do: value > 0

  defp integer_id?(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} -> id > 0
      _invalid -> false
    end
  end

  defp integer_id?(_value), do: false

  defp squash(sql), do: sql |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.join(" ")
end
