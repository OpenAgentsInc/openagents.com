defmodule OpenAgents.Voice.Retention do
  @moduledoc "Enforces the operational voice evidence retention window."

  use GenServer
  import Ecto.Query
  require Logger

  alias OpenAgents.Repo

  alias OpenAgents.Voice.{
    ClientEvent,
    PersistedEvent,
    Recording,
    Recordings,
    ResponseContext,
    ResponseReceipt,
    Session,
    ToolStep,
    TranscriptItem
  }

  @day_ms 24 * 60 * 60 * 1_000
  @purged_instructions "[purged after operational retention]"
  @purged_tool_catalog %{"schema" => "sarah.realtime_tool_catalog.v1", "tools" => []}

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    send(self(), :purge)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:purge, state) do
    # Audio first, and on its own shorter window: a recording should disappear
    # before the lifecycle metadata that describes it. Recordings left open by a
    # closed tab are closed here too, so nothing claims to still be uploading.
    {:ok, aborted} = Recordings.abort_stale()
    {:ok, purged_recordings} = Recordings.purge_expired()

    Logger.info("voice_recording_retention_purge aborted=#{aborted} purged=#{purged_recordings}")

    case purge_expired() do
      {:ok, count} -> Logger.info("voice_retention_purge count=#{count}")
      {:error, reason} -> Logger.error("voice_retention_purge_failed code=#{error_code(reason)}")
    end

    _timer = Process.send_after(self(), :purge, @day_ms)
    {:noreply, state}
  end

  @spec purge_expired(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_expired(now \\ DateTime.utc_now()) do
    retention_days = Application.fetch_env!(:sarah, :voice_operational_retention_days)
    cutoff = DateTime.add(now, -retention_days, :day)

    session_ids =
      Repo.all(
        from(session in Session,
          where:
            session.status in ["ended", "failed"] and session.ended_at < ^cutoff and
              is_nil(session.operational_purged_at),
          order_by: [asc: session.ended_at],
          limit: 500,
          select: session.id
        )
      )

    Enum.reduce_while(session_ids, {:ok, 0}, fn session_id, {:ok, count} ->
      case purge_session(session_id, now) do
        {:ok, :purged} -> {:cont, {:ok, count + 1}}
        {:ok, :already_purged} -> {:cont, {:ok, count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp purge_session(session_id, now) do
    Repo.transaction(fn ->
      session = Repo.get_for_update!(Session, session_id)

      if is_nil(session.operational_purged_at) do
        # Backstop rather than the primary path: audio normally leaves earlier
        # under its own window in `OpenAgents.Voice.Recordings.purge_expired/1`.
        delete_children(Recording, session_id)
        delete_children(ToolStep, session_id)
        delete_children(ResponseReceipt, session_id)
        delete_children(ResponseContext, session_id)
        delete_children(TranscriptItem, session_id)
        delete_children(ClientEvent, session_id)
        delete_children(PersistedEvent, session_id)

        session
        |> Ecto.Changeset.change(%{
          provider_session_id: nil,
          instructions: @purged_instructions,
          tool_catalog: @purged_tool_catalog,
          program_artifact_receipt: nil,
          # The compaction summary is conversation-derived content and leaves
          # with the operational window; compaction_count stays as an
          # aggregate lifecycle fact.
          compaction_summary: nil,
          operational_purged_at: now
        })
        |> Repo.update!()

        :purged
      else
        :already_purged
      end
    end)
  end

  defp delete_children(schema, session_id) do
    {_count, nil} =
      Repo.delete_all(from(row in schema, where: row.voice_session_id == ^session_id))

    :ok
  end

  defp error_code(%{__struct__: module}), do: module |> Module.split() |> List.last()
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "unknown"
end
