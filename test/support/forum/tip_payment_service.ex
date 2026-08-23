defmodule OpenAgents.Forum.TipPaymentServiceStub do
  @moduledoc """
  A payment service double for tests.

  Each test scripts the outcome it wants with `settle/0`, `fail/1`, or
  `unavailable/0`, and the stub records every request it received so a test can
  prove a retry never asked for a second payment.

  The script belongs to the test process. A LiveView or a spawned task reaches
  the same script through `$callers`, the way the Ecto sandbox finds its owner,
  so a tip paid from a LiveView follows the outcome its test asked for.
  """

  @behaviour OpenAgents.Forum.Tips.PaymentService

  @table __MODULE__

  @doc "Creates the script table, owned by the process that calls it."
  def install do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      reference -> reference
    end
  end

  def settle(fee_sats \\ 0), do: put(:outcome, {:settle, fee_sats})

  def fail(failure_code), do: put(:outcome, {:fail, failure_code})

  def unavailable, do: put(:outcome, :unavailable)

  @doc "Every request the stub received, oldest first."
  def requests, do: Enum.reverse(get(:requests, []))

  @impl true
  def pay(request) do
    put(:requests, [request | get(:requests, [])])

    case get(:outcome, :unavailable) do
      {:settle, fee_sats} ->
        {:ok,
         %{
           payment_hash:
             Base.encode16(:crypto.hash(:sha256, request.idempotency_key), case: :lower),
           fee_sats: fee_sats,
           settled_at: DateTime.utc_now()
         }}

      {:fail, failure_code} ->
        {:error, {:payment_failed, failure_code}}

      :unavailable ->
        {:error, :payment_service_unavailable}
    end
  end

  defp put(key, value) do
    install()
    :ets.insert(@table, {{owner(), key}, value})
    :ok
  end

  defp get(key, default) do
    install()

    case :ets.lookup(@table, {owner(), key}) do
      [{_key, value}] -> value
      [] -> default
    end
  end

  # The test process owns the script. A process it started, such as a LiveView,
  # inherits it through `$callers`.
  defp owner do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find(&scripted?/1)
    |> case do
      nil -> self()
      pid -> pid
    end
  end

  defp scripted?(pid), do: :ets.member(@table, {pid, :outcome})
end
