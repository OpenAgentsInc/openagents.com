defmodule OpenAgents.Forum.Tips.PaymentService.MoneyDevKit do
  @moduledoc """
  Pays tips through a MoneyDevKit or LDK wallet service the operator runs.

  The service holds the wallet; this module only asks it to send an amount to a
  destination the recipient supplied, and passes the tip's idempotency key so a
  retry cannot send twice. Configure it in `config/runtime.exs`:

      config :openagents, :forum_tips,
        enabled: true,
        adapter: OpenAgents.Forum.Tips.PaymentService.MoneyDevKit,
        base_url: System.get_env("FORUM_TIPS_WALLET_URL"),
        token: System.get_env("FORUM_TIPS_WALLET_TOKEN")

  Without `base_url` the adapter reports the service as unavailable rather than
  guessing an endpoint.
  """

  @behaviour OpenAgents.Forum.Tips.PaymentService

  require Logger

  @impl true
  def pay(%{destination: destination, amount_sats: amount_sats} = request) do
    config = Application.get_env(:openagents, :forum_tips, [])
    base_url = config[:base_url]

    if is_binary(base_url) and base_url != "" do
      send_payment(base_url, config, %{
        kind: request.kind,
        destination: destination,
        amount_sats: amount_sats,
        idempotency_key: request.idempotency_key
      })
    else
      {:error, :payment_service_unavailable}
    end
  end

  defp send_payment(base_url, config, body) do
    options =
      [
        url: String.trim_trailing(base_url, "/") <> "/v1/payments",
        json: body,
        receive_timeout: Keyword.get(config, :receive_timeout, 30_000),
        retry: false
      ]
      |> put_authorization(config[:token])
      |> Keyword.merge(Keyword.get(config, :req_options, []))

    case Req.post(options) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        settlement(response)

      {:ok, %Req.Response{status: status, body: response}} when status in 400..499 ->
        {:error, {:payment_failed, failure_code(response, "rejected_#{status}")}}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("forum_tip_payment_failed code=unexpected_status status=#{status}")
        {:error, :payment_service_unavailable}

      {:error, transport_error} ->
        Logger.warning("forum_tip_payment_failed code=#{transport_code(transport_error)}")
        {:error, :payment_service_unavailable}
    end
  end

  # Logs carry a transport reason class, never the destination or a response
  # body, so a wallet address cannot reach the log stream.
  defp transport_code(%{reason: reason}) when is_atom(reason), do: reason

  defp transport_code(%struct{}),
    do: struct |> Module.split() |> List.last() |> Macro.underscore()

  defp transport_code(_transport_error), do: "unreachable"

  defp put_authorization(options, token) when is_binary(token) and token != "",
    do: Keyword.put(options, :auth, {:bearer, token})

  defp put_authorization(options, _token), do: options

  defp settlement(%{"payment_hash" => payment_hash} = response) when is_binary(payment_hash) do
    {:ok,
     %{
       payment_hash: payment_hash,
       fee_sats: fee_sats(response["fee_sats"]),
       settled_at: settled_at(response["settled_at"])
     }}
  end

  defp settlement(response), do: {:error, {:payment_failed, failure_code(response, "no_receipt")}}

  defp fee_sats(value) when is_integer(value) and value >= 0, do: value
  defp fee_sats(_value), do: 0

  defp settled_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, settled_at, _offset} -> settled_at
      _error -> DateTime.utc_now()
    end
  end

  defp settled_at(_value), do: DateTime.utc_now()

  defp failure_code(%{"failure_code" => code}, _default) when is_binary(code),
    do: String.slice(code, 0, 64)

  defp failure_code(_response, default), do: default
end
