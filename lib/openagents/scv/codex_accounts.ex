defmodule OpenAgents.SCV.CodexAccounts do
  @moduledoc "Durable authority for operator-connected Codex accounts used by SCVs."

  import Ecto.Query

  require Logger

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Repo
  alias OpenAgents.SCV.CodexLoginSupervisor
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.DriverLoginAttempt

  @topic "scv_codex_accounts:operator"
  @login_lifetime_seconds 15 * 60

  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, @topic)

  @spec list_accounts() :: [DriverAccount.t()]
  def list_accounts do
    Repo.all(from(account in DriverAccount, order_by: [desc: account.inserted_at]))
  end

  @spec start_device_login(User.t(), map()) ::
          {:ok, DriverAccount.t(), DriverLoginAttempt.t(), map()} | {:error, atom()}
  def start_device_login(%User{} = operator, attributes) when is_map(attributes) do
    with true <- Accounts.admin?(operator) or {:error, :not_authorized},
         true <- enabled?() or {:error, :codex_not_enabled},
         {:ok, account, attempt} <- create_pending(operator, attributes),
         {:ok, ceremony} <- CodexLoginSupervisor.start_login(account, attempt) do
      {:ok, account, attempt, ceremony}
    else
      {:error, _reason} = error ->
        error

      false ->
        {:error, :not_authorized}
    end
  end

  def start_device_login(%User{}, _attributes), do: {:error, :attributes_invalid}
  def start_device_login(_operator, _attributes), do: {:error, :not_authorized}

  @spec cancel_device_login(User.t(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def cancel_device_login(%User{} = operator, attempt_id) when is_binary(attempt_id) do
    with true <- Accounts.admin?(operator) or {:error, :not_authorized},
         %DriverLoginAttempt{operator_id: operator_id} = attempt <-
           Repo.get(DriverLoginAttempt, attempt_id),
         true <- operator_id == operator.id or {:error, :not_authorized} do
      CodexLoginSupervisor.cancel(attempt)
    else
      nil -> {:error, :login_not_found}
      {:error, reason} -> {:error, reason}
      false -> {:error, :not_authorized}
    end
  end

  def cancel_device_login(%User{}, _attempt_id), do: {:error, :login_not_found}
  def cancel_device_login(_operator, _attempt_id), do: {:error, :not_authorized}

  @doc false
  def mark_waiting(%DriverLoginAttempt{} = attempt, login_id, verification_url, user_code) do
    result =
      attempt
      |> DriverLoginAttempt.waiting_changeset(%{
        login_id: login_id,
        verification_url: verification_url,
        user_code_digest: :crypto.hash(:sha256, user_code)
      })
      |> Repo.update()

    case result do
      {:ok, waiting} ->
        emit("device_login_waiting", waiting.account_id, waiting.id)
        {:ok, waiting}

      error ->
        error
    end
  end

  @doc false
  def mark_login_completed(%DriverAccount{} = account, %DriverLoginAttempt{} = attempt) do
    emit("device_login_completed", account.id, attempt.id)
  end

  @doc false
  def mark_ready(%DriverAccount{} = account, %DriverLoginAttempt{} = attempt, attributes) do
    Repo.transaction(fn ->
      ready =
        account
        |> DriverAccount.ready_changeset(attributes)
        |> Repo.update!()

      _completed =
        attempt
        |> DriverLoginAttempt.terminal_changeset("succeeded")
        |> Repo.update!()

      ready
    end)
    |> case do
      {:ok, ready} ->
        emit("account_ready", ready.id, attempt.id, %{
          credential_version: ready.credential_version
        })

        broadcast({:account_ready, ready.id})
        {:ok, ready}

      {:error, _reason} ->
        {:error, :account_persistence_failed}
    end
  end

  @doc false
  def mark_failed(%DriverAccount{} = account, %DriverLoginAttempt{} = attempt, code) do
    code = normalize_error_code(code)

    _result =
      Repo.transaction(fn ->
        account
        |> DriverAccount.failed_changeset(code)
        |> Repo.update!()

        attempt
        |> DriverLoginAttempt.terminal_changeset("failed", code)
        |> Repo.update!()
      end)

    broadcast({:account_failed, account.id, code})
    emit("account_failed", account.id, attempt.id, %{error_code: code})
    :ok
  end

  @doc false
  def mark_cancelled(%DriverAccount{} = account, %DriverLoginAttempt{} = attempt) do
    _result =
      Repo.transaction(fn ->
        account
        |> DriverAccount.failed_changeset("login_cancelled")
        |> Repo.update!()

        attempt
        |> DriverLoginAttempt.terminal_changeset("cancelled", "login_cancelled")
        |> Repo.update!()
      end)

    broadcast({:account_cancelled, account.id})
    emit("device_login_cancelled", account.id, attempt.id)
    :ok
  end

  defp create_pending(operator, attributes) do
    Repo.transaction(fn ->
      refs = credential_refs()

      accounts_by_ref =
        Repo.all(
          from(account in DriverAccount,
            where: account.secret_ref in ^refs,
            lock: "FOR UPDATE"
          )
        )
        |> Map.new(&{&1.secret_ref, &1})

      account_slot =
        refs
        |> Enum.find_value(fn ref ->
          available_account_slot(Map.get(accounts_by_ref, ref), ref)
        end)
        |> case do
          nil -> Repo.rollback(:account_capacity_reached)
          slot -> slot
        end

      label = normalized_label(Map.get(attributes, "label") || Map.get(attributes, :label))

      account =
        case account_slot do
          {:new, secret_ref} ->
            %DriverAccount{}
            |> DriverAccount.create_changeset(%{
              id: Ecto.UUID.generate(),
              operator_id: operator.id,
              label: label,
              secret_ref: secret_ref
            })
            |> Repo.insert!()

          {:reuse, failed_account} ->
            failed_account
            |> DriverAccount.retry_changeset(operator.id, label)
            |> Repo.update!()
        end

      attempt =
        %DriverLoginAttempt{}
        |> DriverLoginAttempt.create_changeset(%{
          account_id: account.id,
          operator_id: operator.id,
          expires_at: DateTime.add(DateTime.utc_now(), @login_lifetime_seconds, :second)
        })
        |> Repo.insert!()

      {account, attempt}
    end)
    |> case do
      {:ok, {account, attempt}} -> {:ok, account, attempt}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :account_persistence_failed}
    end
  end

  defp normalized_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "Operator Codex account"
      label -> String.slice(label, 0, 80)
    end
  end

  defp normalized_label(_value), do: "Operator Codex account"

  defp available_account_slot(nil, ref), do: {:new, ref}

  defp available_account_slot(%DriverAccount{status: "failed"} = account, _ref),
    do: {:reuse, account}

  defp available_account_slot(%DriverAccount{}, _ref), do: nil

  defp credential_refs do
    config()
    |> Keyword.get(:credential_refs, [])
    |> Enum.filter(&is_binary/1)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(OpenAgents.PubSub, @topic, {:scv_codex_accounts, event})
  end

  defp emit(type, account_id, attempt_id, extra \\ %{}) do
    metadata =
      Map.merge(
        %{
          schema: "openagents.scv.codex_account.event.v1",
          type: type,
          account_id: account_id,
          attempt_id: attempt_id
        },
        extra
      )

    :telemetry.execute([:openagents, :scv, :codex_account, :event], %{count: 1}, metadata)
    Logger.info("SCV Codex account lifecycle event", Map.to_list(metadata))
    :ok
  end

  defp normalize_error_code(code) when is_atom(code), do: Atom.to_string(code)

  defp normalize_error_code(code) when is_binary(code) do
    code
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "login_failed"
      normalized -> String.slice(normalized, 0, 80)
    end
  end

  defp normalize_error_code(_code), do: "login_failed"

  defp config, do: Application.fetch_env!(:openagents, :scv_codex)
end
