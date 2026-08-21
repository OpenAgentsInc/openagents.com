defmodule OpenAgents.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    original_posthog_env = Application.get_all_env(:posthog)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:posthog) do
        Application.delete_env(:posthog, key)
      end

      for {key, value} <- original_posthog_env do
        Application.put_env(:posthog, key, value)
      end
    end)

    :ok
  end

  test "builds supervisor configuration without convenience options" do
    Application.put_env(:posthog, :api_key, "phc_test_token")
    Application.put_env(:posthog, :enable, false)
    Application.put_env(:posthog, :enable_error_tracking, false)

    config = OpenAgents.Application.posthog_config()

    assert config.enabled
    assert config.api_key == "phc_test_token"
    assert config.api_host == "https://us.i.posthog.com"
  end

  test "returns nil without a project token" do
    Application.put_env(:posthog, :api_key, nil)

    assert OpenAgents.Application.posthog_config() == nil
  end
end
