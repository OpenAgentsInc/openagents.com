defmodule OpenAgentsWeb.PageController do
  use OpenAgentsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
