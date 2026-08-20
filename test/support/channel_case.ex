defmodule OpenAgentsWeb.ChannelCase do
  @moduledoc """
  Shared channel case for authenticated OpenAgents channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint OpenAgentsWeb.Endpoint

      use OpenAgentsWeb, :verified_routes

      import Phoenix.ChannelTest
      import OpenAgentsWeb.ConnCase, only: [github_user: 1]
      import OpenAgentsWeb.ChannelCase
    end
  end

  setup tags do
    OpenAgents.DataCase.setup_sandbox(tags)
    :ok
  end
end
