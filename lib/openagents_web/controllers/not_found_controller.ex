defmodule OpenAgentsWeb.NotFoundController do
  @moduledoc false

  use OpenAgentsWeb, :controller

  def show(conn, _params), do: send_resp(conn, :not_found, "Not found")
end
