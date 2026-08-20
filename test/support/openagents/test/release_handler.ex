defmodule OpenAgents.Test.ReleaseHandler do
  @moduledoc false

  use Agent

  def start_link(initial) do
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def which_releases do
    Agent.get(__MODULE__, & &1.releases)
  end

  def unpack_release(name) do
    version = name |> to_string() |> String.replace_prefix("openagents-", "")

    Agent.update(__MODULE__, fn state ->
      release = {~c"openagents", to_charlist(version), [], :unpacked}
      %{state | releases: [release | state.releases]}
    end)

    {:ok, to_charlist(version)}
  end

  def check_install_release(version) do
    {:ok, other_version(version), ~c"test relup"}
  end

  def install_release(version) do
    version = to_string(version)

    Agent.update(__MODULE__, fn state ->
      releases =
        Enum.map(state.releases, fn {name, found, applications, status} ->
          cond do
            to_string(found) == version -> {name, found, applications, :current}
            status == :current -> {name, found, applications, :old}
            true -> {name, found, applications, status}
          end
        end)

      %{state | releases: releases}
    end)

    {:ok, other_version(version), ~c"test relup"}
  end

  def make_permanent(version) do
    version = to_string(version)

    Agent.update(__MODULE__, fn state ->
      releases =
        Enum.map(state.releases, fn {name, found, applications, status} ->
          cond do
            to_string(found) == version -> {name, found, applications, :permanent}
            status == :permanent -> {name, found, applications, :old}
            true -> {name, found, applications, status}
          end
        end)

      %{state | releases: releases}
    end)

    :ok
  end

  defp other_version(version) do
    if to_string(version) == "0.2.0", do: ~c"0.1.0", else: ~c"0.2.0"
  end
end
