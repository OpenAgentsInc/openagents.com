defmodule OpenAgents.SCV.CodexLogin do
  @moduledoc "Runs one bounded operator-initiated Codex device-login ceremony."

  use GenServer, restart: :temporary

  alias OpenAgents.SCV.CodexAccounts
  alias OpenAgents.SCV.CodexAppServer
  alias OpenAgents.SCV.CodexCredentialStore

  @required_model "gpt-5.6-luna"
  @maximum_auth_bytes 65_536
  @verification_retry_delay_ms 250
  @maximum_verification_attempts 40

  def child_spec(options) do
    attempt = Keyword.fetch!(options, :attempt)

    %{
      id: {__MODULE__, attempt.id},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  def start_link(options) do
    attempt = Keyword.fetch!(options, :attempt)
    name = {:via, Registry, {OpenAgents.SCV.CodexLoginRegistry, attempt.id}}
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec begin(pid()) :: {:ok, map()} | {:error, atom()}
  def begin(server), do: GenServer.call(server, :begin, 30_000)

  @spec snapshot(pid()) :: {:ok, map()} | {:error, atom()}
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @spec cancel(pid()) :: :ok | {:error, atom()}
  def cancel(server), do: GenServer.call(server, :cancel, 15_000)

  @impl true
  def init(options) do
    account = Keyword.fetch!(options, :account)
    attempt = Keyword.fetch!(options, :attempt)
    root = temporary_home(attempt.id)

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- write_config(root) do
      {:ok,
       %{
         account: account,
         app_server: nil,
         attempt: attempt,
         ceremony: nil,
         codex_home: root,
         expiry_timer: nil,
         login_completed?: false,
         login_id: nil,
         verification_attempts: 0,
         verification_timer: nil
       }}
    else
      _error -> {:stop, :login_home_failed}
    end
  end

  @impl true
  def handle_call(:begin, _from, %{app_server: nil} = state) do
    case begin_login(state) do
      {:ok, updated} ->
        {:reply, {:ok, updated.ceremony}, updated}

      {:error, code, updated} ->
        CodexAccounts.mark_failed(updated.account, updated.attempt, code)
        {:stop, :normal, {:error, code}, updated}
    end
  end

  def handle_call(:begin, _from, state), do: {:reply, snapshot_response(state), state}
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_response(state), state}

  def handle_call(:cancel, _from, %{login_id: login_id, app_server: client} = state)
      when is_binary(login_id) and is_pid(client) do
    _result =
      CodexAppServer.request(client, "account/login/cancel", %{"loginId" => login_id})

    CodexAccounts.mark_cancelled(state.account, state.attempt)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:cancel, _from, state) do
    CodexAccounts.mark_cancelled(state.account, state.attempt)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "account/login/completed",
            "params" => %{"loginId" => login_id, "success" => true}
          }}},
        %{app_server: client, login_id: login_id} = state
      ) do
    CodexAccounts.mark_login_completed(state.account, state.attempt)

    {:noreply,
     state
     |> Map.put(:login_completed?, true)
     |> schedule_verification()}
  end

  def handle_info(
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "account/login/completed",
            "params" => %{"loginId" => login_id, "success" => false} = params
          }}},
        %{app_server: client, login_id: login_id} = state
      ) do
    code = if is_binary(params["error"]), do: params["error"], else: "login_failed"
    CodexAccounts.mark_failed(state.account, state.attempt, code)
    {:stop, :normal, state}
  end

  def handle_info(
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "account/updated",
            "params" => %{"authMode" => "chatgpt"}
          }}},
        %{app_server: client, login_completed?: true} = state
      ) do
    {:noreply, trigger_verification(state)}
  end

  def handle_info(
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "account/updated",
            "params" => %{"authMode" => auth_mode}
          }}},
        %{app_server: client, login_completed?: true} = state
      )
      when not is_nil(auth_mode) do
    CodexAccounts.mark_failed(state.account, state.attempt, "chatgpt_account_required")
    {:stop, :normal, state}
  end

  def handle_info(:verify_login, state) do
    state = %{
      state
      | verification_attempts: state.verification_attempts + 1,
        verification_timer: nil
    }

    case complete_login(state) do
      {:ok, updated} ->
        {:stop, :normal, updated}

      {:error, :account_not_ready, updated}
      when updated.verification_attempts < @maximum_verification_attempts ->
        {:noreply, schedule_verification(updated)}

      {:error, code, updated} ->
        CodexAccounts.mark_failed(updated.account, updated.attempt, code)
        {:stop, :normal, updated}
    end
  end

  def handle_info(:expire, state) do
    if is_pid(state.app_server) and is_binary(state.login_id) do
      _result =
        CodexAppServer.request(
          state.app_server,
          "account/login/cancel",
          %{"loginId" => state.login_id}
        )
    end

    CodexAccounts.mark_failed(state.account, state.attempt, "login_expired")
    {:stop, :normal, state}
  end

  def handle_info({:codex_app_server, client, {:exited, _status}}, %{app_server: client} = state) do
    CodexAccounts.mark_failed(state.account, state.attempt, "app_server_exited")
    {:stop, :normal, state}
  end

  def handle_info(
        {:codex_app_server, client, {:protocol_error, reason}},
        %{app_server: client} = state
      ) do
    CodexAccounts.mark_failed(state.account, state.attempt, reason)
    {:stop, :normal, state}
  end

  def handle_info({:codex_app_server, _client, _message}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.expiry_timer), do: Process.cancel_timer(state.expiry_timer)
    if is_reference(state.verification_timer), do: Process.cancel_timer(state.verification_timer)
    if is_pid(state.app_server), do: CodexAppServer.stop(state.app_server)
    File.rm_rf(state.codex_home)
    :ok
  end

  defp begin_login(state) do
    config = config()
    executable = Keyword.fetch!(config, :executable)
    client_options = Keyword.get(config, :client_options, [])

    with {:ok, client} <-
           CodexAppServer.start_link(
             [owner: self(), executable: executable, codex_home: state.codex_home] ++
               client_options
           ),
         {:ok, _initialization} <- initialize(client),
         :ok <- CodexAppServer.notify(client, "initialized"),
         {:ok,
          %{
            "type" => "chatgptDeviceCode",
            "loginId" => login_id,
            "verificationUrl" => verification_url,
            "userCode" => user_code
          }} <-
           CodexAppServer.request(client, "account/login/start", %{
             "type" => "chatgptDeviceCode"
           }),
         :ok <- validate_login_response(login_id, verification_url, user_code),
         {:ok, attempt} <-
           CodexAccounts.mark_waiting(
             state.attempt,
             login_id,
             verification_url,
             user_code
           ) do
      expires_in_ms = max(DateTime.diff(attempt.expires_at, DateTime.utc_now(), :millisecond), 1)
      timer = Process.send_after(self(), :expire, expires_in_ms)

      ceremony = %{
        account_id: state.account.id,
        attempt_id: attempt.id,
        expires_at: attempt.expires_at,
        user_code: user_code,
        verification_url: verification_url
      }

      {:ok,
       %{
         state
         | app_server: client,
           attempt: attempt,
           ceremony: ceremony,
           expiry_timer: timer,
           login_id: login_id
       }}
    else
      {:error, reason} -> {:error, error_code(reason), state}
      _invalid -> {:error, :login_protocol_invalid, state}
    end
  end

  defp initialize(client) do
    CodexAppServer.request(client, "initialize", %{
      "clientInfo" => %{
        "name" => "openagents_scv",
        "title" => "OpenAgents SCV",
        "version" => Application.get_env(:openagents, :build_revision, "image")
      },
      "capabilities" => %{"experimentalApi" => false}
    })
  end

  defp complete_login(state) do
    with {:ok, account_response} <-
           CodexAppServer.request(state.app_server, "account/read", %{"refreshToken" => false}),
         {:ok, account_metadata} <- account_metadata(account_response),
         {:ok, model_response} <-
           CodexAppServer.request(state.app_server, "model/list", %{
             "includeHidden" => true,
             "limit" => 100
           }),
         {:ok, model_metadata} <- model_metadata(model_response),
         {:ok, _rate_limits} <-
           CodexAppServer.request(state.app_server, "account/rateLimits/read", %{}),
         {:ok, auth_json} <- read_auth_json(state.codex_home),
         {:ok, version} <- CodexCredentialStore.put(state.account, auth_json),
         {:ok, account} <-
           CodexAccounts.mark_ready(state.account, state.attempt, %{
             credential_version: version,
             account_email: account_metadata.email,
             plan_type: account_metadata.plan_type,
             available_models: model_metadata.models,
             reasoning_efforts: model_metadata.reasoning_efforts,
             last_verified_at: DateTime.utc_now()
           }) do
      {:ok, %{state | account: account}}
    else
      {:error, reason} -> {:error, error_code(reason), state}
      _invalid -> {:error, :login_completion_invalid, state}
    end
  end

  defp account_metadata(%{
         "account" => %{"type" => "chatgpt", "planType" => plan_type} = account
       })
       when is_binary(plan_type) do
    email = if is_binary(account["email"]), do: account["email"], else: nil
    {:ok, %{email: email, plan_type: plan_type}}
  end

  defp account_metadata(%{"account" => nil}), do: {:error, :account_not_ready}
  defp account_metadata(_response), do: {:error, :chatgpt_account_required}

  defp model_metadata(%{"data" => models}) when is_list(models) do
    admitted =
      Enum.filter(models, fn model ->
        model["id"] == @required_model or model["model"] == @required_model
      end)

    if admitted == [] do
      {:error, :required_model_unavailable}
    else
      model_ids =
        models
        |> Enum.map(&(&1["id"] || &1["model"]))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      reasoning_efforts =
        admitted
        |> Enum.flat_map(&Map.get(&1, "supportedReasoningEfforts", []))
        |> Enum.map(fn option -> option["reasoningEffort"] end)
        |> Enum.filter(&(&1 in ["none", "low"]))
        |> Enum.uniq()

      if reasoning_efforts == [] do
        {:error, :required_reasoning_effort_unavailable}
      else
        {:ok, %{models: model_ids, reasoning_efforts: reasoning_efforts}}
      end
    end
  end

  defp model_metadata(_response), do: {:error, :model_catalog_invalid}

  defp read_auth_json(codex_home) do
    path = Path.join(codex_home, "auth.json")

    with {:ok, contents} when byte_size(contents) in 2..@maximum_auth_bytes <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(contents) do
      {:ok, contents}
    else
      _invalid -> {:error, :auth_cache_invalid}
    end
  end

  defp validate_login_response(login_id, verification_url, user_code)
       when is_binary(login_id) and byte_size(login_id) in 1..128 and is_binary(user_code) and
              byte_size(user_code) in 1..64 do
    case URI.new(verification_url) do
      {:ok, %URI{scheme: "https", host: "auth.openai.com", path: "/codex/device"}} -> :ok
      _invalid -> {:error, :verification_url_invalid}
    end
  end

  defp validate_login_response(_login_id, _verification_url, _user_code),
    do: {:error, :login_protocol_invalid}

  defp snapshot_response(%{ceremony: ceremony}) when is_map(ceremony), do: {:ok, ceremony}
  defp snapshot_response(_state), do: {:error, :login_not_ready}

  defp trigger_verification(state) do
    if is_reference(state.verification_timer), do: Process.cancel_timer(state.verification_timer)
    send(self(), :verify_login)
    %{state | verification_timer: nil}
  end

  defp schedule_verification(%{verification_timer: nil} = state) do
    timer = Process.send_after(self(), :verify_login, @verification_retry_delay_ms)
    %{state | verification_timer: timer}
  end

  defp schedule_verification(state), do: state

  defp write_config(codex_home) do
    path = Path.join(codex_home, "config.toml")
    contents = "cli_auth_credentials_store = \"file\"\n"

    with :ok <- File.write(path, contents, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp temporary_home(attempt_id) do
    root = Keyword.get(config(), :temporary_root, System.tmp_dir!())
    Path.join(root, "openagents-scv-codex-login-#{attempt_id}")
  end

  defp error_code(reason) when is_atom(reason), do: reason
  defp error_code(_reason), do: :login_failed

  defp config, do: Application.fetch_env!(:openagents, :scv_codex)
end
