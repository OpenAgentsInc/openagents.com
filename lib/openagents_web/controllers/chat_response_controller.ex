defmodule OpenAgentsWeb.ChatResponseController do
  @moduledoc "Provides account-authenticated programmatic access to the chat runtime."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Chat.Runner

  def create(conn, params) do
    with {:ok, request} <- Runner.request_from_params(params) do
      if params["stream"] == true do
        stream(conn, request)
      else
        complete(conn, request)
      end
    else
      {:error, :invalid_input} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          "error" => %{"code" => "invalid_input", "message" => "Provide valid input or messages."}
        })
    end
  end

  defp complete(conn, request) do
    {result, events} = collect(request, conn.assigns.current_user)

    case result do
      {:ok, completion} ->
        json(conn, response_body(completion, events))

      {:error, reason} ->
        provider_error(conn, reason)
    end
  end

  defp stream(conn, request) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    owner = self()
    stream_id = make_ref()

    task =
      Task.Supervisor.async_nolink(OpenAgents.ProviderTaskSupervisor, fn ->
        Runner.stream(request, conn.assigns.current_user, fn event ->
          send(owner, {:account_chat_event, stream_id, event})
        end)
      end)

    stream_loop(conn, task, stream_id)
  end

  defp stream_loop(conn, task, stream_id) do
    receive do
      {:account_chat_event, ^stream_id, event} ->
        case chunk(conn, sse(event_payload(event))) do
          {:ok, conn} -> stream_loop(conn, task, stream_id)
          {:error, _closed} -> conn
        end

      {ref, {:ok, completion}} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])

        {:ok, conn} =
          chunk(
            conn,
            sse(%{"type" => "response.completed", "response" => response_body(completion, [])})
          )

        conn

      {ref, {:error, reason}} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])

        {:ok, conn} =
          chunk(conn, sse(%{"type" => "response.failed", "error" => error_body(reason)}))

        conn

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:ok, conn} =
          chunk(conn, sse(%{"type" => "response.failed", "error" => error_body(reason)}))

        conn
    after
      130_000 ->
        Task.shutdown(task, :brutal_kill)

        {:ok, conn} =
          chunk(conn, sse(%{"type" => "response.failed", "error" => error_body(:timeout)}))

        conn
    end
  end

  defp collect(request, user) do
    key = {__MODULE__, make_ref()}
    Process.put(key, [])

    result =
      Runner.stream(request, user, fn event -> Process.put(key, [event | Process.get(key)]) end)

    events = key |> Process.get() |> Enum.reverse()
    Process.delete(key)
    {result, events}
  end

  defp response_body(completion, events) do
    %{
      "id" => completion["id"] || completion["assistant_message_id"],
      "object" => "response",
      "status" => "completed",
      "model" => completion["model"],
      "output_text" => completion["assistant_content"] || "",
      "reasoning" => completion["reasoning_summary"],
      "reasoning_items" => completion["reasoning_items"] || [],
      "tool_calls" => completion["tool_calls"] || [],
      "events" => Enum.map(events, &event_payload/1)
    }
  end

  defp event_payload({:text_delta, delta}),
    do: %{"type" => "response.output_text.delta", "delta" => delta}

  defp event_payload({:reasoning_delta, delta}),
    do: %{"type" => "response.reasoning.delta", "delta" => delta}

  defp event_payload({:tool_call_started, call}),
    do: %{"type" => "response.tool_call.started", "tool_call" => call}

  defp event_payload({:tool_call_completed, call}),
    do: %{"type" => "response.tool_call.completed", "tool_call" => call}

  defp event_payload({:tool_call_failed, call}),
    do: %{"type" => "response.tool_call.failed", "tool_call" => call}

  defp event_payload(event), do: %{"type" => "response.event", "data" => inspect(event)}

  defp sse(payload), do: "data: " <> Jason.encode!(payload) <> "\n\n"

  defp provider_error(conn, reason) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{"error" => error_body(reason)})
  end

  defp error_body(reason),
    do: %{
      "code" => error_code(reason),
      "message" => "The chat provider could not complete the request."
    }

  defp error_code({:provider_error, code, _detail}), do: code
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "provider_error"
end
