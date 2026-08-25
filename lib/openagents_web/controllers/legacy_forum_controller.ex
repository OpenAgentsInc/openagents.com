defmodule OpenAgentsWeb.LegacyForumController do
  @moduledoc """
  Explicit redirect map for legacy forum URLs.

  The one-time import carried legacy topic and post ids into this
  application's own tables, but old links may still use the surface paths that
  the Effect forum served. This controller resolves those links through
  `OpenAgents.Forum` and redirects to the canonical topic route. An unknown or
  malformed id answers 404; it never asks the mirror.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Forum

  def topic(conn, %{"id" => id}) do
    case Forum.fetch_readable_topic(id, []) do
      {:ok, topic} ->
        redirect(conn, to: ~p"/forum/t/#{topic.id}")

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def post(conn, %{"id" => id}) do
    case Forum.fetch_post(id) do
      {:ok, post} ->
        redirect(conn, to: ~p"/forum/t/#{post.topic_id}")

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    send_resp(conn, :not_found, "Not found")
  end
end
