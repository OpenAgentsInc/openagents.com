defmodule OpenAgents.Incidents do
  @moduledoc """
  Durable, owner-scoped failure records — the one place Sarah, the owner, and
  every user can read *why* something failed.

  Recording is resilient by construction: an incident write must never break the
  failure it is describing, so `record/1` rescues its own faults and returns an
  error tuple rather than raising into the finalize path that called it. Context
  is scrubbed and byte-bounded before it is stored.
  """

  import Ecto.Query

  alias OpenAgents.Incidents.{Incident, Triage}
  alias OpenAgents.Memory.Redaction
  alias OpenAgents.Repo

  require Logger

  @maximum_context_bytes 8_192
  @maximum_string_chars 500
  @default_list_limit 20
  @maximum_list_limit 100
  @recurrence_window_seconds 86_400

  @doc """
  Record a failure and run the escalation ladder: classify, record, notify the
  right parties, and (for anomalous incidents) spawn a fixer. This is the one
  entrypoint the failure origins call. Resilient — a fault here never breaks the
  failure being reported.
  """
  @spec report(map()) :: {:ok, Incident.t()} | {:error, term()}
  def report(attributes) when is_map(attributes) do
    case record(attributes) do
      {:ok, incident} ->
        _routed = OpenAgents.Incidents.Notifier.route(incident)

        if Triage.escalate?(incident.severity),
          do: OpenAgents.Incidents.Fixer.maybe_spawn(incident)

        {:ok, incident}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("incident_report_failed code=#{OpenAgents.OperationalLog.code(error)}")
      {:error, :incident_report_failed}
  end

  @doc """
  Record one failure. Classifies severity from the code when not given, scrubs
  and bounds the context, and inserts. Returns `{:ok, incident}` or
  `{:error, reason}` — never raises.
  """
  @spec record(map()) :: {:ok, Incident.t()} | {:error, term()}
  def record(attributes) when is_map(attributes) do
    # Callers pass a typed code. Last-resort default is `task_exit`, never
    # `unknown` — an untyped death is still a task exit, not a mystery.
    code = to_string(attributes[:code] || attributes["code"] || "task_exit")
    severity = attributes[:severity] || attributes["severity"] || Triage.classify(code)

    attrs =
      attributes
      |> Map.put(:code, String.slice(code, 0, 128))
      |> Map.put(:severity, severity)
      |> Map.update(:summary, nil, &bound_string/1)
      |> Map.update(:context, %{}, &sanitize_context/1)

    %Incident{}
    |> Incident.changeset(attrs)
    |> Repo.insert()
  rescue
    error ->
      Logger.error("incident_record_failed code=#{OpenAgents.OperationalLog.code(error)}")
      {:error, :incident_record_failed}
  end

  @doc "Most recent incidents for an owner, newest first, bounded."
  @spec list_recent(binary(), keyword()) :: [Incident.t()]
  def list_recent(owner_user_id, opts \\ [])

  def list_recent(owner_user_id, opts) when is_binary(owner_user_id) do
    limit = list_limit(opts)

    Incident
    |> where([i], i.owner_user_id == ^owner_user_id)
    |> maybe_filter_conversation(opts[:conversation_id])
    |> maybe_filter_severity(opts[:severity])
    |> order_by([i], desc: i.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_recent(_owner, _opts), do: []

  @doc "One incident, scoped to its owner so it is never cross-read."
  @spec get(binary(), binary()) :: {:ok, Incident.t()} | {:error, :not_found}
  def get(id, owner_user_id) when is_binary(id) and is_binary(owner_user_id) do
    case Repo.get_by(Incident, id: id, owner_user_id: owner_user_id) do
      nil -> {:error, :not_found}
      incident -> {:ok, incident}
    end
  end

  def get(_id, _owner), do: {:error, :not_found}

  @doc "How many times this code has hit this owner within the recurrence window."
  @spec recurrence_count(binary(), String.t()) :: non_neg_integer()
  def recurrence_count(owner_user_id, code)
      when is_binary(owner_user_id) and is_binary(code) do
    since = DateTime.add(DateTime.utc_now(), -@recurrence_window_seconds, :second)

    Incident
    |> where([i], i.owner_user_id == ^owner_user_id and i.code == ^code)
    |> where([i], i.inserted_at >= ^since)
    |> Repo.aggregate(:count)
  end

  def recurrence_count(_owner, _code), do: 0

  @doc "How many fixer jobs this owner has had spawned within the given window."
  @spec active_fixer_count(binary(), integer()) :: non_neg_integer()
  def active_fixer_count(owner_user_id, window_seconds)
      when is_binary(owner_user_id) and is_integer(window_seconds) do
    since = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    Incident
    |> where([i], i.owner_user_id == ^owner_user_id and not is_nil(i.fixer_job_id))
    |> where([i], i.inserted_at >= ^since)
    |> Repo.aggregate(:count)
  end

  def active_fixer_count(_owner, _window), do: 0

  @doc "Move an incident to a new lifecycle status (owner-scoped)."
  @spec mark_status(Incident.t(), String.t()) :: {:ok, Incident.t()} | {:error, term()}
  def mark_status(%Incident{} = incident, status) do
    incident
    |> Incident.changeset(%{status: status})
    |> Repo.update()
  end

  @doc "Link the fixer job now healing this incident and flip it to `fixing`."
  @spec attach_fixer(Incident.t(), binary()) :: {:ok, Incident.t()} | {:error, term()}
  def attach_fixer(%Incident{} = incident, fixer_job_id) when is_binary(fixer_job_id) do
    incident
    |> Incident.changeset(%{fixer_job_id: fixer_job_id, status: "fixing"})
    |> Repo.update()
  end

  # ── Context hygiene ────────────────────────────────────────────────────────

  # Scrub free text of credential material and truncate long values, then cap
  # the whole map's encoded size so an incident can never carry a secret or an
  # unbounded blob.
  defp sanitize_context(context) when is_map(context) do
    bounded =
      context
      |> Enum.map(fn {key, value} -> {to_string(key), sanitize_value(value)} end)
      |> Map.new()

    if byte_size(Jason.encode!(bounded)) <= @maximum_context_bytes,
      do: bounded,
      else: %{"truncated" => true, "note" => "context exceeded #{@maximum_context_bytes} bytes"}
  rescue
    _error -> %{}
  end

  defp sanitize_context(_context), do: %{}

  defp sanitize_value(value) when is_binary(value) do
    case Redaction.classify(value) do
      {:reject, _reason} -> "[redacted]"
      _allowed -> bound_string(value)
    end
  end

  defp sanitize_value(value) when is_map(value), do: sanitize_context(value)
  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_value(value), do: value

  defp bound_string(value) when is_binary(value),
    do: String.slice(value, 0, @maximum_string_chars)

  defp bound_string(value), do: value

  defp list_limit(opts) do
    opts |> Keyword.get(:limit, @default_list_limit) |> min(@maximum_list_limit) |> max(1)
  end

  defp maybe_filter_conversation(query, nil), do: query

  defp maybe_filter_conversation(query, conversation_id),
    do: where(query, [i], i.conversation_id == ^conversation_id)

  defp maybe_filter_severity(query, nil), do: query
  defp maybe_filter_severity(query, severity), do: where(query, [i], i.severity == ^severity)
end
