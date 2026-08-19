defmodule OpenAgentsWeb.AdminRecordingController do
  @moduledoc """
  Streams one call recording to the operator.

  ## Why there is no `Range` support

  A WebM/Opus (or fragmented MP4) recording is only media as the ordered
  concatenation of its slices: the header lives in the first slice and every
  later one depends on it. Serving an arbitrary byte range would hand a browser
  something that is not a valid stream, and computing real ranges means unsealing
  and measuring every chunk first — which is a scan, not a seek.

  So this reader advertises `accept-ranges: none` and streams the whole thing.
  The visible cost is that the operator can play and pause but cannot scrub, and
  Safari may decline to play a range-less stream at all. That is a deliberate,
  documented v1 limit rather than an oversight; `docs/voice/RECORDINGS.md` records
  what fixing it would take.
  """

  use OpenAgentsWeb, :controller

  import Plug.Conn

  alias OpenAgents.Admin
  alias OpenAgents.Repo
  alias OpenAgents.Voice.Recordings

  def show(conn, %{"id" => id}) do
    case Admin.get_recording(id) do
      {:ok, recording, _owner} ->
        if recording.chunk_count > 0 and
             recording.status in OpenAgents.Voice.Recording.playable_statuses() do
          stream_recording(conn, recording)
        else
          send_resp(conn, :not_found, "")
        end

      {:error, :not_found} ->
        send_resp(conn, :not_found, "")
    end
  end

  defp stream_recording(conn, recording) do
    conn =
      conn
      # No charset: this is binary media, not text in an encoding.
      |> put_resp_content_type(Recordings.content_type(recording), nil)
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("accept-ranges", "none")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_chunked(:ok)

    # Repo.stream needs a transaction, and the chunks are unsealed one slice at a
    # time so a long call never lands in memory whole.
    {:ok, final_conn} =
      Repo.transaction(
        fn ->
          recording
          |> Recordings.stream()
          |> Enum.reduce_while(conn, fn slice, current_conn ->
            case chunk(current_conn, slice) do
              {:ok, next_conn} -> {:cont, next_conn}
              {:error, :closed} -> {:halt, current_conn}
            end
          end)
        end,
        timeout: :infinity
      )

    final_conn
  end
end
