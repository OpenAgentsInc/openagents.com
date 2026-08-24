defmodule OpenAgentsWeb.DataController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.DataRights.AccountExport
  alias OpenAgents.{Conversations, DataRights}

  def show(conn, _params) do
    with {:ok, user, owner, conversation} <- scope(conn),
         {:ok, export} <- DataRights.export(user, owner, conversation),
         {:ok, body} <- Jason.encode(export) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="sarah-account-data.json")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(:ok, body)
    else
      _unavailable -> send_resp(conn, :not_found, "Data export is unavailable.")
    end
  end

  # The same owner scope as `show/2`: the ATIF trajectory is a second bounded
  # projection of the same account-owned graph, never a wider one.
  def export_atif(conn, _params) do
    with {:ok, user, owner, conversation} <- scope(conn),
         {:ok, export} <- OpenAgents.DataRights.AtifExport.build(user, owner, conversation),
         {:ok, body} <- Jason.encode(export) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="sarah-conversation-#{conversation.id}-atif.json")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(:ok, body)
    else
      _unavailable -> send_resp(conn, :not_found, "Trajectory export is unavailable.")
    end
  end

  @doc """
  The account-scoped export of forge-owned and forum-owned records.

  Scoped to the account rather than to a conversation, so it answers for an
  account that has never opened chat. `AccountExport.build/1` takes the
  authenticated account and nothing else, so no parameter can widen it to
  another account's records.
  """
  def export_account(conn, _params) do
    with %{status: "active"} = user <- conn.assigns.current_user,
         {:ok, export} <- AccountExport.build(user),
         {:ok, body} <- Jason.encode(export) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="openagents-account-data.json")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(:ok, body)
    else
      _unavailable -> send_resp(conn, :not_found, "Account export is unavailable.")
    end
  end

  def delete(conn, %{"privacy" => %{"confirmation" => "DELETE MY SARAH DATA"}}) do
    with {:ok, user, owner, conversation} <- scope(conn),
         {:ok, :deleted} <- DataRights.delete(user, owner, conversation) do
      conn
      |> redirect(to: ~p"/sarah")
    else
      {:error, :text_turn_in_progress} ->
        conn |> put_status(:conflict) |> text("Stop Sarah's typed response before deletion.")

      {:error, :voice_session_in_progress} ->
        conn |> put_status(:conflict) |> text("End voice before deletion.")

      _unavailable ->
        send_resp(conn, :not_found, "Account data is unavailable.")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> text("Type DELETE MY SARAH DATA exactly to confirm deletion.")
  end

  def reset(conn, _params) do
    if DataRights.reset_enabled?() do
      with {:ok, user, owner, conversation} <- scope(conn),
           {:ok, :deleted} <- DataRights.delete(user, owner, conversation) do
        redirect(conn, to: ~p"/sarah")
      else
        {:error, :text_turn_in_progress} ->
          conn |> put_status(:conflict) |> text("Stop Sarah's typed response before the reset.")

        {:error, :voice_session_in_progress} ->
          conn |> put_status(:conflict) |> text("End voice before the reset.")

        _unavailable ->
          send_resp(conn, :not_found, "Account data is unavailable.")
      end
    else
      send_resp(conn, :not_found, "Not found.")
    end
  end

  defp scope(conn) do
    with %{status: "active"} = user <- conn.assigns.current_user,
         conversation when not is_nil(conversation) <-
           Conversations.get_conversation_for_user(user) do
      {:ok, user, Conversations.get_conversation_owner!(conversation), conversation}
    else
      _missing -> {:error, :not_found}
    end
  end
end
