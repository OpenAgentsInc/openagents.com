defmodule OpenAgents.SarahDataCase do
  @moduledoc """
  Sarah-specific data case used by the lifted Sarah test suite.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias OpenAgents.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import OpenAgents.DataCase
    end
  end

  setup tags do
    OpenAgents.DataCase.setup_sandbox(tags)
    :ok
  end
end
