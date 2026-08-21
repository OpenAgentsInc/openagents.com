defmodule OpenAgents.Analytics do
  @moduledoc """
  The single capture boundary for product analytics events.

  Every server-side PostHog capture goes through `capture/3`. The boundary
  enforces policy in one place:

  - Capture is a no-op unless `OPENAGENTS_POSTHOG_PROJECT_TOKEN` configured a
    project token at boot.
  - Standard properties (`environment`, `app_revision`) merge onto every event.
  - Property keys on the sensitive denylist are dropped, oversized values are
    truncated, and non-scalar shapes are bounded before anything leaves.
  - A capture failure never fails its caller: it logs and returns `:ok`.

  See docs/2026-08-21-posthog-integration-runbook.md for the event taxonomy and
  the identity rules. Browser events identify with the same canonical
  `user_<id>` distinct ID that this module derives for accounts.
  """

  require Logger

  import Plug.Conn, only: [get_req_header: 2]

  @sensitive_keys ~w(
    access_token api_key apikey authorization cookie credential ciphertext
    password refresh_token secret secret_key_base sdp state token verifier
  )
  @maximum_properties 40
  @maximum_list_items 20
  @maximum_map_entries 20
  @maximum_depth 3
  @maximum_value_bytes 512

  @type event_name :: String.t()
  @type distinct_id :: String.t()

  @doc """
  Whether capture is configured. False in development without a token, in the
  test environment, and wherever the project token was never set at boot.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:openagents, :posthog_project_token) do
      token when is_binary(token) -> String.trim(token) != ""
      _other -> false
    end
  end

  @doc """
  The canonical PostHog distinct ID for an account: `user_<database id>`.

  Account IDs are UUID strings. Browser `posthog.identify` calls must pass
  exactly this value so client and server events attach to one person.
  Already-prefixed values pass through unchanged, so the function is safe to
  call with any stored identifier.
  """
  @spec distinct_id(OpenAgents.Accounts.User.t() | term()) :: distinct_id()
  def distinct_id(%{id: id}) when is_binary(id), do: "user_#{id}"

  def distinct_id(id) when is_binary(id) do
    if String.starts_with?(id, ["user_", "system_", "visitor_", "anonymous"]) do
      id
    else
      "user_#{id}"
    end
  end

  def distinct_id(id) when is_integer(id), do: "user_#{id}"

  @doc """
  A synthetic distinct ID for events no account owns (forge pushes,
  deployments). Each surface gets its own stable person so operational volume
  stays separable from human behavior.
  """
  @spec system_distinct_id(String.t()) :: distinct_id()
  def system_distinct_id(surface) when is_binary(surface), do: "system_#{surface}"

  @doc """
  The browser's anonymous distinct ID when tracing headers are present, or
  `"anonymous"` otherwise. Tracing headers are client-controlled analytics
  hints; never use them for authorization decisions.
  """
  @spec browser_distinct_id(Plug.Conn.t()) :: distinct_id()
  def browser_distinct_id(conn) do
    case get_req_header(conn, "x-posthog-distinct-id") do
      [value | _] when byte_size(value) in 1..255 -> value
      _other -> "anonymous"
    end
  end

  @doc """
  Capture one product event. Returns `:ok` unconditionally; failures log and
  swallow so instrumentation can never break a request or a turn.
  """
  @spec capture(event_name(), distinct_id(), map()) :: :ok
  def capture(event, distinct_id, properties \\ %{})

  def capture(event, distinct_id, properties)
      when is_binary(event) and is_binary(distinct_id) and is_map(properties) do
    if enabled?() do
      dispatch(event, distinct_id, standard_properties(properties))
    else
      :ok
    end
  end

  def capture(_event, _distinct_id, _properties), do: :ok

  defp dispatch(event, distinct_id, properties) do
    sink().capture(event, distinct_id, properties)
    :ok
  rescue
    error ->
      Logger.warning(
        "analytics_capture_failed event=#{event} code=#{OpenAgents.OperationalLog.code(error)}"
      )

      :ok
  catch
    _kind, _reason ->
      Logger.warning("analytics_capture_failed event=#{event} code=analytics_capture_crashed")
      :ok
  end

  defp sink do
    Application.get_env(:openagents, :analytics_sink, OpenAgents.Analytics.PostHogSink)
  end

  defp standard_properties(properties) do
    surface = Map.get(properties, "surface") || Map.get(properties, :surface) || "server"

    %{"environment" => environment(), "app_revision" => revision(), "surface" => surface}
    |> Map.merge(sanitize(properties))
  end

  defp environment do
    case Application.get_env(:openagents, :runtime_environment) do
      value when is_atom(value) -> Atom.to_string(value)
      _other -> "unknown"
    end
  end

  defp revision, do: OpenAgents.BuildInfo.revision()

  # ── property sanitization ────────────────────────────────────────────────

  defp sanitize(properties) when is_map(properties) do
    properties
    |> Enum.take(@maximum_properties)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      with {:ok, string_key} <- sanitize_key(key),
           {:ok, sanitized} <- sanitize_value(value, 1) do
        Map.put(acc, string_key, sanitized)
      else
        :drop -> acc
      end
    end)
  end

  defp sanitize_key(key) when is_binary(key) do
    normalized = String.downcase(key)

    if normalized in @sensitive_keys or sensitive_suffix?(normalized) do
      :drop
    else
      {:ok, key}
    end
  end

  defp sanitize_key(key) when is_atom(key), do: sanitize_key(Atom.to_string(key))
  defp sanitize_key(_key), do: :drop

  defp sensitive_suffix?(key) do
    String.ends_with?(key, ["_token", "_secret", "_password", "_credential", "_ciphertext"])
  end

  defp sanitize_value(nil, _depth), do: {:ok, nil}
  defp sanitize_value(value, _depth) when is_boolean(value), do: {:ok, value}
  defp sanitize_value(value, _depth) when is_integer(value), do: {:ok, value}
  defp sanitize_value(value, _depth) when is_float(value), do: {:ok, value}

  defp sanitize_value(value, _depth) when is_binary(value) do
    if byte_size(value) > @maximum_value_bytes do
      {:ok, "[truncated]"}
    else
      {:ok, value}
    end
  end

  defp sanitize_value(value, depth) when is_atom(value) and depth <= @maximum_depth,
    do: {:ok, Atom.to_string(value)}

  defp sanitize_value(value, depth) when is_list(value) and depth < @maximum_depth do
    items =
      value
      |> Enum.take(@maximum_list_items)
      |> Enum.reduce_while([], fn item, acc ->
        case sanitize_value(item, depth + 1) do
          {:ok, sanitized} -> {:cont, [sanitized | acc]}
          :drop -> {:cont, acc}
        end
      end)
      |> Enum.reverse()

    {:ok, items}
  end

  defp sanitize_value(value, depth) when is_map(value) and depth < @maximum_depth do
    if is_struct(value) do
      :drop
    else
      entries =
        value
        |> Enum.take(@maximum_map_entries)
        |> Enum.reduce(%{}, fn {key, inner}, acc ->
          with {:ok, string_key} <- sanitize_key(key),
               {:ok, sanitized} <- sanitize_value(inner, depth + 1) do
            Map.put(acc, string_key, sanitized)
          else
            :drop -> acc
          end
        end)

      {:ok, entries}
    end
  end

  defp sanitize_value(_value, _depth), do: :drop
end
