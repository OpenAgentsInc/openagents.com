defmodule OpenAgents.DataRights.ResetGateTest do
  use ExUnit.Case, async: false

  alias OpenAgents.DataRights

  setup do
    previous_flag = Application.get_env(:openagents, :conversation_reset_enabled, false)
    previous_environment = Application.get_env(:openagents, :runtime_environment)

    on_exit(fn ->
      Application.put_env(:openagents, :conversation_reset_enabled, previous_flag)
      Application.put_env(:openagents, :runtime_environment, previous_environment)
    end)

    :ok
  end

  test "the flag enables the reset control outside production" do
    Application.put_env(:openagents, :conversation_reset_enabled, true)

    for environment <- [:development, :test, :staging] do
      Application.put_env(:openagents, :runtime_environment, environment)
      assert DataRights.reset_enabled?()
    end
  end

  # The environment decides last. A production deployment that sets the flag
  # gets nothing: no control on the page, and no route behind it, because the
  # controller asks this same question before it deletes anything.
  test "production refuses the reset control even with the flag set" do
    Application.put_env(:openagents, :conversation_reset_enabled, true)
    Application.put_env(:openagents, :runtime_environment, :production)

    refute DataRights.reset_enabled?()
  end

  test "the control stays off wherever the flag is unset" do
    Application.put_env(:openagents, :conversation_reset_enabled, false)

    for environment <- [:development, :test, :staging, :production] do
      Application.put_env(:openagents, :runtime_environment, environment)
      refute DataRights.reset_enabled?()
    end
  end
end
