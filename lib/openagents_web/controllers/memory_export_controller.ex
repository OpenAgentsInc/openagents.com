defmodule OpenAgentsWeb.MemoryExportController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.{Conversations, ProfileMemory}

  def show(conn, _params) do
    with %{status: "active"} = user <- conn.assigns.current_user,
         conversation when not is_nil(conversation) <-
           Conversations.get_conversation_for_user(user),
         owner <- Conversations.get_conversation_owner!(conversation),
         {:ok, browser_export} <- ProfileMemory.export(owner),
         export <- account_export(browser_export),
         {:ok, body} <- Jason.encode(export) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="sarah-memory-account.json")
      )
      |> send_resp(:ok, body)
    else
      _unavailable -> send_resp(conn, :not_found, "Memory export is unavailable.")
    end
  end

  defp account_export(export) do
    export
    |> Map.put("schema", "sarah.profile_memory_account_export.v1")
    |> Map.put("scope", "authenticated_github_user")
  end
end
