defmodule OpenAgentsWeb.SarahChannelCase do
  @moduledoc """
  Sarah-specific channel case used by the lifted Sarah channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint OpenAgentsWeb.Endpoint

      use OpenAgentsWeb, :verified_routes

      import Phoenix.ChannelTest
      import OpenAgentsWeb.SarahConnCase, only: [github_user: 1]
      import OpenAgentsWeb.SarahChannelCase
    end
  end

  setup tags do
    OpenAgents.DataCase.setup_sandbox(tags)
    :ok
  end
end
