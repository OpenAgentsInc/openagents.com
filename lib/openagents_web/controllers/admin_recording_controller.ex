defmodule OpenAgentsWeb.AdminRecordingController do
  @moduledoc """
  Streams one call recording to an authenticated operator.

  This is the route that hands one person another person's voice, so ADMIN-001
  names it and `test/openagents_web/operator_surface_test.exs` holds it in the
  enumerated operator surface. The read is not audited; ADMIN-001 records why.

  The reader sends the complete ordered recording because later WebM, Ogg, and
  MP4 chunks depend on the first chunk's container header. It advertises no
  range support, unseals one chunk at a time, and never loads a complete call
  into memory.
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
      |> put_resp_content_type(Recordings.content_type(recording), nil)
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("accept-ranges", "none")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_chunked(:ok)

    {:ok, final_conn} =
      Repo.transaction(
        fn ->
          recording
          |> Recordings.stream()
          |> Enum.reduce_while(conn, fn recording_chunk, current_conn ->
            case chunk(current_conn, recording_chunk) do
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
