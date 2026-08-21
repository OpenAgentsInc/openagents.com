defmodule OpenAgents.SCV.CodexAppServer do
  @moduledoc """
  Owns one local Codex app-server process and its JSONL JSON-RPC connection.

  The client keeps standard output protocol-only, bounds incomplete lines, and
  rejects server requests it does not implement. Codex tracing stays disabled
  for the device-login process so one-time codes and account payloads do not
  enter application logs.
  """

  use GenServer

  @maximum_line_bytes 1_048_576
  @default_timeout 15_000

  @type request_result :: {:ok, map()} | {:error, atom() | map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc false
  @spec start(keyword()) :: GenServer.on_start()
  def start(options) do
    GenServer.start(__MODULE__, options)
  end

  @spec request(pid(), String.t(), map(), timeout()) :: request_result()
  def request(server, method, params \\ %{}, timeout \\ @default_timeout)
      when is_binary(method) and is_map(params) do
    GenServer.call(server, {:request, method, params}, timeout)
  catch
    :exit, {:timeout, _detail} -> {:error, :request_timeout}
    :exit, _reason -> {:error, :server_unavailable}
  end

  @spec notify(pid(), String.t(), map()) :: :ok | {:error, atom()}
  def notify(server, method, params \\ %{}) when is_binary(method) and is_map(params) do
    GenServer.call(server, {:notify, method, params})
  catch
    :exit, _reason -> {:error, :server_unavailable}
  end

  @spec stop(pid()) :: :ok
  def stop(server) when is_pid(server) do
    GenServer.stop(server, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(options) do
    owner = Keyword.fetch!(options, :owner)
    executable = Keyword.fetch!(options, :executable)
    codex_home = Keyword.fetch!(options, :codex_home)
    args = Keyword.get(options, :args, ["app-server", "--listen", "stdio://"])

    with :ok <- validate_executable(executable),
         :ok <- File.mkdir_p(codex_home),
         :ok <- File.chmod(codex_home, 0o700),
         {:ok, port} <- open_port(executable, args, codex_home, options) do
      {:ok,
       %{
         buffer: "",
         next_id: 1,
         owner: owner,
         pending: %{},
         port: port
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    id = state.next_id
    payload = %{"id" => id, "method" => method, "params" => params}

    case send_message(state.port, payload) do
      :ok ->
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    payload =
      if params == %{},
        do: %{"method" => method},
        else: %{"method" => method, "params" => params}

    {:reply, send_message(state.port, payload), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    combined = state.buffer <> data

    if byte_size(combined) > @maximum_line_bytes and not String.contains?(combined, "\n") do
      notify_owner(state.owner, {:protocol_error, :line_too_large})
      {:stop, :protocol_line_too_large, state}
    else
      pieces = :binary.split(combined, "\n", [:global])
      {buffer, lines} = List.pop_at(pieces, -1)
      state = Enum.reduce(lines, %{state | buffer: buffer}, &handle_line/2)
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Enum.each(state.pending, fn {_id, from} -> GenServer.reply(from, {:error, :server_exited}) end)

    notify_owner(state.owner, {:exited, status})
    {:stop, :normal, %{state | pending: %{}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_port(state.port), do: Port.close(state.port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "result" => result}} when is_integer(id) ->
        reply_pending(state, id, {:ok, result})

      {:ok, %{"id" => id, "error" => error}} when is_integer(id) ->
        reply_pending(state, id, {:error, error})

      {:ok, %{"id" => id, "method" => method}} when is_integer(id) ->
        _ =
          send_message(state.port, %{
            "id" => id,
            "error" => %{"code" => -32601, "message" => "Method not supported"}
          })

        notify_owner(state.owner, {:server_request_rejected, method})
        state

      {:ok, %{"method" => _method} = notification} ->
        notify_owner(state.owner, {:notification, notification})
        state

      {:ok, _unknown} ->
        notify_owner(state.owner, {:protocol_error, :unknown_message})
        state

      {:error, _reason} ->
        notify_owner(state.owner, {:protocol_error, :invalid_json})
        state
    end
  end

  defp reply_pending(state, id, response) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {from, pending} ->
        GenServer.reply(from, response)
        %{state | pending: pending}
    end
  end

  defp open_port(executable, args, codex_home, options) do
    environment = isolated_environment(codex_home, options)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :hide,
          :use_stdio,
          args: Enum.map(args, &String.to_charlist/1),
          cd: String.to_charlist(codex_home),
          env: port_environment(environment)
        ]
      )

    {:ok, port}
  rescue
    _error -> {:error, :process_start_failed}
  end

  defp isolated_environment(codex_home, options) do
    allowed = %{
      "CODEX_HOME" => codex_home,
      "HOME" => codex_home,
      "LANG" => "C.UTF-8",
      "LC_ALL" => "C.UTF-8",
      "LOG_FORMAT" => "json",
      "PATH" =>
        Keyword.get(options, :path, System.get_env("PATH", "/usr/local/bin:/usr/bin:/bin")),
      "RUST_LOG" => "off",
      "TMPDIR" => codex_home
    }

    current = Map.new(System.get_env(), fn {key, _value} -> {key, false} end)
    Map.merge(current, allowed)
  end

  defp port_environment(environment) do
    Enum.map(environment, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp send_message(port, payload) do
    case Port.command(port, Jason.encode!(payload) <> "\n") do
      true -> :ok
      false -> {:error, :server_unavailable}
    end
  rescue
    _error -> {:error, :server_unavailable}
  end

  defp notify_owner(owner, message) do
    send(owner, {:codex_app_server, self(), message})
  end

  defp validate_executable(executable) when is_binary(executable) do
    if File.regular?(executable), do: :ok, else: {:error, :executable_not_found}
  end

  defp validate_executable(_executable), do: {:error, :executable_not_found}
end
