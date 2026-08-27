defmodule OpenAgentsWeb.LegacyChangelogController do
  use OpenAgentsWeb, :controller

  def index(conn, _params), do: redirect(conn, to: ~p"/docs/changelog")
end
