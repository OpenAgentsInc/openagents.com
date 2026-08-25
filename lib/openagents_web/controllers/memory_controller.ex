defmodule OpenAgentsWeb.MemoryController do
  @moduledoc """
  The account's memories: write one, read them back, remove one.

  These three routes are the whole write path. Recall does not run here — it
  runs server-side inside `POST /api/v1/responses`, so the CLI, the web app,
  and a direct API caller all get memory attached to their turns without any of
  them implementing retrieval. What a client needs to implement is a `remember`
  tool that posts here when the reader explicitly asks to have something
  remembered, and nothing else.

  Explicit only. Nothing on this surface infers a memory from a conversation:
  a memory exists because somebody asked for it.

  Corrections supersede rather than edit. `POST` accepts `supersedes` — the id
  of a memory this one replaces — and there is no `PATCH`, because the store
  keeps the chain a wrong memory was corrected through instead of overwriting
  it. `DELETE` is the other operation, and it means what it says: the row is
  gone, not marked.

  The account scope is `chat:account`, the same lane threads and chat already
  use, because a memory belongs to an account rather than to a repository or a
  thread.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Memories
  alias OpenAgents.Memories.Memory
  alias OpenAgentsWeb.ApiError

  @doc """
  Writes one memory.

  Body: `body` (required), `bucket` (`user` or `learned`, `user` by default),
  `source_ref` (the thread or session the request came out of), and
  `supersedes` (the id of a live memory of this account that this one
  replaces).
  """
  def create(conn, params) do
    user = conn.assigns.current_user

    attrs = %{
      "body" => params["body"],
      "bucket" => params["bucket"] || Memory.default_bucket(),
      "source_ref" => params["source_ref"],
      "supersedes" => params["supersedes"]
    }

    case Memories.create(user, attrs) do
      {:ok, memory} ->
        conn
        |> put_status(:created)
        |> json(%{"memory" => view(memory)})

      {:error, :quota_reached} ->
        ApiError.refuse(conn, "memory_quota_reached",
          message:
            "This account already holds #{Memories.maximum_live_memories()} memories. " <>
              "Remove one, or supersede one, before writing another."
        )

      {:error, :supersedes_not_found} ->
        ApiError.validation_failed(conn, %{
          "supersedes" => ["names no live memory of this account"]
        })

      {:error, changeset} ->
        ApiError.changeset(conn, changeset)
    end
  end

  @doc """
  The account's memories, newest first.

  Query parameters: `bucket` to narrow to one bucket, `limit` to bound the
  page, and `include_superseded=true` to read the corrections behind the live
  rows as well.
  """
  def index(conn, params) do
    memories = Memories.list(conn.assigns.current_user, listing_options(params))

    json(conn, %{"memories" => Enum.map(memories, &view/1)})
  end

  @doc "Removes one memory outright."
  def delete(conn, %{"id" => id}) do
    case Memories.delete(conn.assigns.current_user, id) do
      {:ok, memory} -> json(conn, %{"memory" => view(memory)})
      {:error, :not_found} -> ApiError.not_found(conn)
    end
  end

  defp listing_options(params) do
    []
    |> bucket(params["bucket"])
    |> limit(params["limit"])
    |> superseded(params["include_superseded"])
  end

  defp bucket(opts, value) when value in ["user", "learned"], do: [{:bucket, value} | opts]
  defp bucket(opts, _absent), do: opts

  defp limit(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> [{:limit, parsed} | opts]
      _unreadable -> opts
    end
  end

  defp limit(opts, value) when is_integer(value) and value > 0, do: [{:limit, value} | opts]
  defp limit(opts, _absent), do: opts

  defp superseded(opts, value) when value in [true, "true", "1"],
    do: [{:include_superseded, true} | opts]

  defp superseded(opts, _absent), do: opts

  defp view(%Memory{} = memory) do
    %{
      "id" => memory.id,
      "bucket" => memory.bucket,
      "body" => memory.body,
      "source_ref" => memory.source_ref,
      "superseded_by" => memory.superseded_by_id,
      "created_at" => stamp(memory.inserted_at)
    }
  end

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
