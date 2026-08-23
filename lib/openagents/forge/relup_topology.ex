defmodule OpenAgents.Forge.RelupTopology do
  @moduledoc """
  Classifies the running application topology for OTP release handling.

  `:release_handler.install_release/1` starts by building the set of processes
  it will suspend, code-change, and resume. For each running application
  `release_handler_1:get_master_procs/3` asks
  `:supervisor.get_callback_module/1` for the application's top supervisor. That
  function reads the process state as a `supervisor` record, so it raises
  `badrecord` for any application whose top process is not an OTP `supervisor` —
  an Elixir `DynamicSupervisor`, a Horde supervisor, or a bare `GenServer`
  returned from `Application.start/2`.

  `libring` is the concrete case. `HashRing.App.start/2` returns the pid of a
  `DynamicSupervisor`, so OTP logs `cannot find top supervisor for application
  libring` and drops that supervisor from the set it upgrades. The application's
  own top process is then never suspended and never code-changed while the
  release installs around it, and `:release_handler.check_install_release/1`
  never looks, so nothing refuses before the install begins.

  Neither outcome is a correct upgrade, so this module refuses first. It runs
  on the target node, reads only process structure, and returns a bounded list
  naming the application and its registered supervisor. A candidate it refuses
  is still eligible for the immutable rolling replacement path, which does not
  depend on OTP release handling.
  """

  @schema "openagents.relup-topology.v1"

  # A refusal is an operational message, not a dump. Enough entries to see the
  # shape of the problem, each short enough to survive a bounded receipt.
  @maximum_entries 16
  @maximum_entry_bytes 96

  @doc """
  Report every running application OTP release handling cannot inspect.

  Returns a bounded, content-free map. `"incompatible"` names each application
  whose top supervisor `:supervisor.get_callback_module/1` refuses to identify.
  """
  def report(opts \\ []) do
    applications = applications(opts)

    incompatible =
      applications
      |> Enum.flat_map(&describe(&1, opts))
      |> Enum.sort()
      |> Enum.take(@maximum_entries)

    %{
      "schema" => @schema,
      "applications" => length(applications),
      "incompatible" => incompatible
    }
  end

  @doc """
  Refuse when any running application has a top supervisor OTP cannot identify.

  Returns `:ok`, or `{:error, {:incompatible_topology, entries}}` where each
  entry is `"application:Supervisor"`.
  """
  def refuse(opts \\ []) do
    case report(opts)["incompatible"] do
      [] -> :ok
      entries -> {:error, {:incompatible_topology, entries}}
    end
  end

  @doc """
  Identify one running application's top supervisor the way OTP does.

  Returns `{:ok, callback_module}` for an application OTP can inspect,
  `:no_supervision_tree` for a library application or one without an
  application master, and `{:error, reason}` when the top process is not an OTP
  supervisor.
  """
  def top_supervisor(application, opts \\ []) when is_atom(application) do
    case master(application, opts) do
      master when is_pid(master) -> root_callback(master, opts)
      _other -> :no_supervision_tree
    end
  end

  defp describe(application, opts) do
    case top_supervisor(application, opts) do
      {:error, _reason} -> [entry(application, opts)]
      _compatible -> []
    end
  end

  defp entry(application, opts) do
    supervisor =
      case master(application, opts) do
        master when is_pid(master) -> root_name(master, opts)
        _other -> "unknown"
      end

    "#{application}:#{supervisor}"
    |> String.slice(0, @maximum_entry_bytes)
  end

  defp root_callback(master, opts) do
    with {:ok, root} <- root(master, opts) do
      callback = Keyword.get(opts, :callback_module, &:supervisor.get_callback_module/1)

      try do
        case callback.(root) do
          module when is_atom(module) -> {:ok, module}
          _other -> {:error, :unreadable_top_supervisor}
        end
      rescue
        _error -> {:error, :unreadable_top_supervisor}
      catch
        _kind, _value -> {:error, :unreadable_top_supervisor}
      end
    end
  end

  defp root_name(master, opts) do
    with {:ok, root} <- root(master, opts) do
      case Process.info(root, :registered_name) do
        {:registered_name, name} when is_atom(name) and name != nil ->
          name |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

        _other ->
          "unregistered"
      end
    end
    |> case do
      name when is_binary(name) -> name
      _other -> "unknown"
    end
  end

  defp root(master, opts) do
    child = Keyword.get(opts, :application_child, &:application_master.get_child/1)

    try do
      case child.(master) do
        {root, _module} when is_pid(root) -> {:ok, root}
        _other -> {:error, :no_top_supervisor}
      end
    rescue
      _error -> {:error, :no_top_supervisor}
    catch
      _kind, _value -> {:error, :no_top_supervisor}
    end
  end

  defp master(application, opts) do
    lookup = Keyword.get(opts, :application_master, &:application_controller.get_master/1)

    try do
      lookup.(application)
    rescue
      _error -> :undefined
    catch
      _kind, _value -> :undefined
    end
  end

  defp applications(opts) do
    Keyword.get(opts, :applications, &running_applications/0).()
  end

  # The same list `release_handler_1:get_application_names/0` folds over.
  defp running_applications do
    for {application, _description, _version} <- Application.started_applications(),
        do: application
  end
end
