defmodule OpenAgents.Stacks.EventDispatcher do
  @moduledoc """
  Delivers stack outbox events to PubSub subscribers.

  Stack mutations write `OpenAgents.Stacks.StackEvent` rows inside the
  same metadata transaction (the transactional outbox). This worker polls
  for undelivered rows, broadcasts each on the owning repository's stack
  event topic in insertion order, and marks it delivered in the same
  transaction. Claiming uses `FOR UPDATE SKIP LOCKED`, so multiple nodes
  never race on one row — but delivery is still at-least-once (a crash
  between broadcast and commit redelivers), so consumers deduplicate by
  event ID.
  """
  use GenServer

  import Ecto.Query

  alias OpenAgents.Repo
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEvent

  @batch_size 100

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    gen_server_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, gen_server_options)
  end

  @doc "Subscribes the caller to a repository's stack events."
  def subscribe(repository_id) do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, topic(repository_id))
  end

  @doc "The stack event topic for one repository."
  def topic(repository_id), do: "stack_events:#{repository_id}"

  @doc "Synchronously delivers every pending outbox row."
  def drain(server \\ __MODULE__), do: GenServer.call(server, :drain, 30_000)

  @doc """
  Delivers one batch of undelivered events in insertion order.

  Returns the number of rows delivered. Callers that need everything
  flushed call it until it returns `0`.
  """
  def deliver_pending do
    {:ok, count} =
      Repo.transaction(fn ->
        events =
          Repo.all(
            from event in StackEvent,
              join: stack in Stack,
              on: stack.id == event.stack_id,
              where: is_nil(event.delivered_at),
              order_by: [asc: event.inserted_at, asc: event.id],
              limit: @batch_size,
              lock: fragment("FOR UPDATE OF ? SKIP LOCKED", event),
              select: {event, stack.repository_id}
          )

        now = DateTime.utc_now()

        Enum.each(events, fn {event, repository_id} ->
          broadcast(event, repository_id)

          event
          |> StackEvent.delivered_changeset(now)
          |> Repo.update!()
        end)

        length(events)
      end)

    count
  end

  defp broadcast(event, repository_id) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      topic(repository_id),
      {:stack_event,
       %{
         id: event.id,
         stack_id: event.stack_id,
         event_type: event.event_type,
         stack_version: event.stack_version,
         actor_user_id: event.actor_user_id,
         payload: event.payload,
         inserted_at: event.inserted_at
       }}
    )
  end

  @impl true
  def init(options) do
    state = %{poll_interval_ms: Keyword.get(options, :poll_interval_ms, poll_interval_ms())}
    schedule(state.poll_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, {:ok, drain_now(0)}, state}
  end

  @impl true
  def handle_info(:poll, state) do
    _count = deliver_pending()
    schedule(state.poll_interval_ms)
    {:noreply, state}
  end

  defp drain_now(total) do
    case deliver_pending() do
      0 -> total
      count -> drain_now(total + count)
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp poll_interval_ms do
    Application.get_env(:openagents, :stack_event_dispatcher_poll_interval_ms, 1_000)
  end
end
