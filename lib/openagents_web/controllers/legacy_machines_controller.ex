defmodule OpenAgentsWeb.LegacyMachinesController do
  @moduledoc false

  use OpenAgentsWeb, :controller

  def show(conn, _params) do
    redirect(conn, to: ~p"/computers")
  end
end
