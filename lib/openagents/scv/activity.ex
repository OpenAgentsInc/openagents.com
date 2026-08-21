defmodule OpenAgents.SCV.Activity do
  @moduledoc """
  Publishes a bounded, content-free projection of active SCV runs.

  The projection accepts only normalized SCV lifecycle metadata. It replaces
  the internal run ID with a one-way public label and derives activity text
  from admitted event and tool names. Objectives, repository paths, arguments,
  tool output, report text, credentials, and diagnostic content never enter the
  public state.
  """

  use GenServer

  @telemetry_event [:openagents, :scv, :event]
  @public_topic "scv_activity:public"
  @replication_topic "scv_activity:replication"
  @maximum_entries 32
  @default_expire_after_ms :timer.seconds(30)
  @default_prune_interval_ms :timer.seconds(5)
  @admitted_tools ~w(apply_patch bash edit glob grep list read todowrite write)

  @type public_entry :: %{String.t() => String.t() | float()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc "Observes one versioned SCV event."
  @spec observe(map(), GenServer.server()) :: :ok
  def observe(event, server \\ __MODULE__), do: GenServer.cast(server, {:observe, event})

  @doc "Returns the bounded public projection, newest activity first."
  @spec public_projection(GenServer.server()) :: [public_entry()]
  def public_projection(server \\ __MODULE__) do
    GenServer.call(server, :public_projection)
  catch
    :exit, _reason -> []
  end

  @doc false
  @spec project_event(map()) :: public_entry() | nil
  def project_event(event) do
    case public_command(event) do
      {:upsert, _id, public} -> public
      {:touch, _id, public} -> public
      _ignored_or_terminal -> nil
    end
  end

  @doc "Subscribes the caller to `{:scv_activity, entries}` updates."
  @spec subscribe(module()) :: :ok | {:error, term()}
  def subscribe(pubsub \\ OpenAgents.PubSub),
    do: Phoenix.PubSub.subscribe(pubsub, @public_topic)

  @doc false
  def handle_telemetry(_event_name, _measurements, metadata, activity) do
    send(activity, {:telemetry_event, metadata})
  end

  @impl true
  def init(options) do
    pubsub = Keyword.get(options, :pubsub, OpenAgents.PubSub)
    telemetry? = Keyword.get(options, :telemetry, true)
    expire_after_ms = Keyword.get(options, :expire_after_ms, @default_expire_after_ms)
    prune_interval_ms = Keyword.get(options, :prune_interval_ms, @default_prune_interval_ms)

    if pubsub, do: Phoenix.PubSub.subscribe(pubsub, @replication_topic)
    schedule_prune(prune_interval_ms)

    handler_id = {__MODULE__, self()}

    if telemetry? do
      :ok =
        :telemetry.attach(handler_id, @telemetry_event, &__MODULE__.handle_telemetry/4, self())
    end

    {:ok,
     %{
       entries: %{},
       expire_after_ms: expire_after_ms,
       handler_id: if(telemetry?, do: handler_id),
       prune_interval_ms: prune_interval_ms,
       pubsub: pubsub
     }}
  end

  @impl true
  def handle_call(:public_projection, _from, state) do
    {:reply, project(state.entries), state}
  end

  @impl true
  def handle_cast({:observe, event}, state) do
    case public_command(event) do
      :ignore ->
        {:noreply, state}

      command ->
        state = apply_and_publish(state, command)
        replicate(state.pubsub, command)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:telemetry_event, event}, state) do
    case public_command(event) do
      :ignore ->
        {:noreply, state}

      command ->
        state = apply_and_publish(state, command)
        replicate(state.pubsub, command)
        {:noreply, state}
    end
  end

  def handle_info({:scv_activity_replication, origin, _command}, state)
      when origin == self(),
      do: {:noreply, state}

  def handle_info({:scv_activity_replication, _origin, command}, state) do
    {:noreply, apply_and_publish(state, command)}
  end

  def handle_info(:prune, state) do
    entries = prune_expired(state.entries)

    if entries != state.entries do
      broadcast_public(state.pubsub, project(entries))
    end

    schedule_prune(state.prune_interval_ms)
    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{handler_id: nil}), do: :ok

  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  defp public_command(event) when is_map(event) do
    with "openagents.scv.event.v1" <- value(event, :schema),
         run_id when is_binary(run_id) <- value(event, :run_id),
         {:ok, _uuid} <- Ecto.UUID.cast(run_id),
         type when is_binary(type) <- value(event, :type) do
      id = public_id(run_id)

      case type do
        terminal when terminal in ["process_finished", "run_finished"] ->
          {:delete, id}

        "heartbeat" ->
          {:touch, id, base_entry(id, "Working within its resource budget")}

        "run_preparing" ->
          {:upsert, id, base_entry(id, "Preparing an admitted SCV run")}

        "process_starting" ->
          {:upsert, id, base_entry(id, "Starting its coding runtime")}

        "process_started" ->
          {:upsert, id, base_entry(id, "Coding runtime started")}

        "driver_started" ->
          {:upsert, id, base_entry(id, "Codex runtime started")}

        "driver_session_started" ->
          {:upsert, id, base_entry(id, "Started its isolated Codex session")}

        "turn_started" ->
          {:upsert, id, base_entry(id, "Investigating its admitted objective")}

        "message_delta" ->
          {:upsert, id, base_entry(id, "Preparing its bounded report")}

        "usage_updated" ->
          {:touch, id, base_entry(id, "Working within its token budget")}

        "tool_started" ->
          {:upsert, id, codex_tool_entry(id, event)}

        "tool_completed" ->
          {:upsert, id, codex_tool_entry(id, event)}

        "turn_finished" ->
          {:upsert, id, base_entry(id, "Persisting its terminal report")}

        "opencode_event" ->
          {:upsert, id, open_code_entry(id, event)}

        _other ->
          :ignore
      end
    else
      _invalid -> :ignore
    end
  end

  defp public_command(_event), do: :ignore

  defp open_code_entry(id, event) do
    event_type = value(event, :event_type)
    tool = admitted_tool(value(event, :tool))

    {text, tool} =
      case {event_type, tool} do
        {"tool_use", "read"} -> {"Reading repository context", "read"}
        {"tool_use", "grep"} -> {"Searching repository context", "grep"}
        {"tool_use", "glob"} -> {"Mapping repository files", "glob"}
        {"tool_use", "list"} -> {"Listing repository context", "list"}
        {"tool_use", "edit"} -> {"Applying a bounded code edit", "edit"}
        {"tool_use", "apply_patch"} -> {"Applying a bounded code patch", "apply_patch"}
        {"tool_use", "write"} -> {"Writing an admitted workspace file", "write"}
        {"tool_use", "bash"} -> {"Running an admitted command", "bash"}
        {"tool_use", "todowrite"} -> {"Updating its work plan", "todowrite"}
        {"step_start", _tool} -> {"Starting its next model step", nil}
        {"step_finish", _tool} -> {"Finished a model step", nil}
        {"text", _tool} -> {"Preparing its bounded report", nil}
        {_event_type, _tool} -> {"Working on its admitted objective", nil}
      end

    id
    |> base_entry(text)
    |> maybe_put_tool(tool)
  end

  defp admitted_tool(tool) when tool in @admitted_tools, do: tool
  defp admitted_tool(_tool), do: nil

  defp codex_tool_entry(id, event) do
    case value(event, :activity_kind) do
      "command" -> base_entry(id, "Running a read-only repository command")
      "searching" -> base_entry(id, "Searching repository context")
      "viewing" -> base_entry(id, "Viewing repository context")
      "file_change" -> base_entry(id, "Reviewing a proposed file change")
      _activity -> base_entry(id, "Using an admitted Codex tool")
    end
  end

  defp base_entry(id, text) do
    %{
      "id" => id,
      "label" => id |> String.replace_prefix("scv-", "SCV ") |> String.upcase(),
      "status" => "running",
      "weight" => 0.4,
      "text" => text
    }
  end

  defp maybe_put_tool(entry, nil), do: Map.delete(entry, "tool")
  defp maybe_put_tool(entry, tool), do: Map.put(entry, "tool", tool)

  defp apply_and_publish(state, command) do
    entries = apply_command(state.entries, command, state.expire_after_ms)
    entries = retain_latest(entries)
    broadcast_public(state.pubsub, project(entries))
    %{state | entries: entries}
  end

  defp apply_command(entries, {:delete, id}, _expire_after_ms), do: Map.delete(entries, id)

  defp apply_command(entries, {:upsert, id, public}, expire_after_ms) do
    Map.put(entries, id, timed_entry(public, expire_after_ms))
  end

  defp apply_command(entries, {:touch, id, public}, expire_after_ms) do
    current = Map.get(entries, id, %{public: public})
    Map.put(entries, id, timed_entry(current.public, expire_after_ms))
  end

  defp timed_entry(public, expire_after_ms) do
    %{
      expires_at: monotonic_ms() + expire_after_ms,
      order: next_order(),
      public: public
    }
  end

  defp prune_expired(entries) do
    now = monotonic_ms()
    Map.reject(entries, fn {_id, entry} -> entry.expires_at <= now end)
  end

  defp retain_latest(entries) when map_size(entries) <= @maximum_entries, do: entries

  defp retain_latest(entries) do
    entries
    |> Enum.sort_by(fn {_id, entry} -> entry.order end, :desc)
    |> Enum.take(@maximum_entries)
    |> Map.new()
  end

  defp project(entries) do
    entries
    |> Map.values()
    |> Enum.sort_by(& &1.order, :desc)
    |> Enum.map(& &1.public)
  end

  defp replicate(nil, _command), do: :ok

  defp replicate(pubsub, command) do
    Phoenix.PubSub.broadcast(pubsub, @replication_topic, {
      :scv_activity_replication,
      self(),
      command
    })
  end

  defp broadcast_public(nil, _projection), do: :ok

  defp broadcast_public(pubsub, projection) do
    Phoenix.PubSub.broadcast(pubsub, @public_topic, {:scv_activity, projection})
  end

  defp public_id(run_id) do
    digest = :crypto.hash(:sha256, run_id) |> Base.encode16(case: :lower) |> String.slice(0, 8)
    "scv-" <> digest
  end

  defp value(event, key), do: Map.get(event, key) || Map.get(event, Atom.to_string(key))
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp next_order, do: System.unique_integer([:monotonic, :positive])

  defp schedule_prune(nil), do: :ok
  defp schedule_prune(interval_ms), do: Process.send_after(self(), :prune, interval_ms)
end
