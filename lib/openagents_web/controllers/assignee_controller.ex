defmodule OpenAgentsWeb.AssigneeController do
  use OpenAgentsWeb, :controller

  def index(conn, _params) do
    json(conn, %{assignees: []})
  end

  def show(conn, %{"assignee" => _assignee}) do
    send_resp(conn, :not_found, "")
  end
end
