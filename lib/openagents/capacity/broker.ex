defmodule OpenAgents.Capacity.Broker do
  @moduledoc false

  @behaviour OpenAgents.Capacity.Evidence

  @allowed_keys [
    "id",
    "logical",
    "active_reservations",
    "reported_free",
    "queued",
    "observed_limit",
    "budget_limit",
    "drain_limit",
    "observed_at",
    "estimated_wait_seconds",
    "private",
    "incident_drained"
  ]

  @impl true
  def fetch(_viewer) do
    config = Application.get_env(:openagents, OpenAgents.Capacity, [])
    url = Keyword.get(config, :broker_url)

    if is_binary(url) and String.trim(url) != "" do
      request_options = [
        url: String.trim_trailing(url, "/") <> "/capacity",
        method: :get,
        receive_timeout: Keyword.get(config, :broker_timeout_ms, 2_000),
        retry: false
      ]

      request_options =
        case Keyword.get(config, :broker_token) do
          token when is_binary(token) and token != "" ->
            Keyword.put(request_options, :headers, [{"authorization", "Bearer " <> token}])

          _missing ->
            request_options
        end

      case Req.request(request_options) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          parse(body)

        {:ok, %Req.Response{}} ->
          {:error, :broker_unavailable}

        {:error, _reason} ->
          {:error, :broker_unavailable}
      end
    else
      {:error, :unconfigured}
    end
  end

  defp parse(%{"classes" => classes}) when is_list(classes) do
    {:ok, %{"classes" => Enum.flat_map(classes, &parse_class/1)}}
  end

  defp parse(_invalid), do: {:error, :invalid_broker_response}

  defp parse_class(class) when is_map(class) do
    id = Map.get(class, "id")

    if is_binary(id) do
      [Map.take(class, @allowed_keys)]
    else
      []
    end
  end

  defp parse_class(_invalid), do: []
end
