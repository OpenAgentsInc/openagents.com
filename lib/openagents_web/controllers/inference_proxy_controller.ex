defmodule OpenAgentsWeb.InferenceProxyController do
  @moduledoc """
  The Sarah inference proxy: an OpenAI-compatible `/chat/completions` surface
  a delegated probe calls with its delegation-scoped grant as the bearer.

  It authenticates the grant (never a provider credential), translates the
  request into a provider-neutral `OpenAgents.Providers.Request`, fans it into
  the `OpenAgents.Providers.Provider` that serves the grant's model
  (`OpenAgents.Inference.Models`, PROVIDER-001) — so the provider credential
  never leaves the server (RELEASE-002) — meters token usage against the
  grant's budget (VOICE-010 pattern), and streams the typed provider events
  back as chat-completions SSE that probe's parser consumes. Provider JSON,
  credentials, and raw errors never cross this boundary.

  Model selection is honest (PROVIDER-002): a body that names a model the
  catalog does not serve, or a served model other than the grant's, is refused
  with a typed error naming the served set, never answered by another model.
  Every 200 attributes the effective model — the `x-openagents-model` header
  and each chunk's `model` field — so a client renders what answered.

  What answered is read back off the response rather than assumed from the
  request. One lane can substitute: the Vercel AI Gateway is configured with a
  fallback model list, so a call for `google/gemini-3.7-flash` can be served by
  `openai/gpt-5.6-luna` and still return 200. The serving model therefore
  decides three things — the name attributed on the response, the lane whose
  health is recorded, and the rate table the usage record is priced against
  (METER-001). A substitutable lane whose response discloses no model is
  attributed `unresolved` and priced at nothing, because naming the requested
  model would be a claim the deployment cannot support.

  The probe→proxy hop is buffered (the provider still streams from the vendor
  internally); probe's transport reads the whole body before parsing, so this
  matches its consumer and keeps failure handling honest.
  """

  use OpenAgentsWeb, :controller

  require Logger

  alias OpenAgents.Inference
  alias OpenAgents.Inference.Models
  alias OpenAgents.Providers.{Request, ToolDefinition, ToolOutput}

  def create(conn, _params) do
    # The :api pipeline already parsed the JSON body into body_params; the
    # proxy never re-reads or re-parses it.
    with {:ok, token} <- bearer(conn),
         {:ok, grant} <- resolve(token),
         {:ok, model} <- route(grant, conn.body_params),
         :ok <- serving(model),
         :ok <- requested_model(model, conn.body_params),
         {:ok, request} <- build_request(model, conn.body_params) do
      run(conn, grant, model, request)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # ── request assembly ────────────────────────────────────────────────────

  # The grant's model names the provider and the string that provider is called
  # with. A grant minted before the model was routable — or one whose model has
  # since been withdrawn — is refused here rather than sent to a provider that
  # does not serve it.
  defp route(grant, body) do
    if no_model_in_body?(body) and grant.model_id == Models.default_id() do
      {:ok, Models.select()}
    else
      case Models.fetch(grant.model_id) do
        {:ok, model} -> {:ok, model}
        :error -> {:error, :model_unavailable}
      end
    end
  end

  defp no_model_in_body?(body) do
    case Map.get(body, "model") do
      absent when absent in [nil, ""] -> true
      _ -> false
    end
  end

  # A routed model whose adapter reports no credential is refused before the
  # call, not answered by another lane (PROVIDER-002).
  defp serving(model) do
    if Models.available?(model), do: :ok, else: {:error, :model_unavailable}
  end

  # The grant pins the model, and a body that names one must name the same
  # model. Ignoring the field would answer a request that asked for one model
  # with another and say nothing — the silent substitution of issue #160 —
  # so a disagreement is a typed refusal that names the served set
  # (PROVIDER-002). Either spelling of the granted model (public id or vendor
  # string) is the same name.
  defp requested_model(model, body) do
    case Map.get(body, "model") do
      absent when absent in [nil, ""] ->
        :ok

      requested when is_binary(requested) ->
        case Models.fetch(requested) do
          {:ok, %{id: id}} when id == model.id -> :ok
          {:ok, %{id: other}} -> {:error, {:model_mismatch, other, model.id}}
          :error -> {:error, {:model_not_served, requested}}
        end

      _not_a_string ->
        {:error, :invalid_request}
    end
  end

  defp build_request(model, %{"messages" => messages} = body) when is_list(messages) do
    {system, turns} = Enum.split_with(messages, &(role(&1) == "system"))

    request = %Request{
      # The grant pins the model; a request body cannot select another.
      model_id: model.provider_model,
      instructions: join_text(system),
      input: Enum.flat_map(turns, &input_message/1),
      tool_definitions: tool_definitions(body["tools"]),
      tool_outputs: tool_outputs(turns),
      max_output: model.max_output
    }

    if request.input == [] do
      {:error, :empty_input}
    else
      {:ok, request}
    end
  end

  defp build_request(_model, _body), do: {:error, :invalid_request}

  defp input_message(%{"role" => "tool"}), do: []

  defp input_message(message) do
    tool_calls = message_tool_calls(message["tool_calls"])

    case {content_text(message), tool_calls} do
      {"", []} -> []
      {text, []} -> [%{role: role(message), content: text}]
      # An assistant turn that called tools is part of the transcript even
      # when it carried no prose: dropping it would orphan the tool outputs
      # that answer it.
      {text, calls} -> [%{role: role(message), content: text, tool_calls: calls}]
    end
  end

  # The assistant tool calls a caller replays from its own history, in the
  # chat-completions shape it received them. Arguments stay the raw JSON
  # string; the proxy never interprets them.
  defp message_tool_calls(calls) when is_list(calls) do
    Enum.flat_map(calls, fn
      %{"id" => id, "function" => %{"name" => name} = function}
      when is_binary(id) and id != "" and is_binary(name) and name != "" ->
        [%{call_id: id, name: name, arguments: text(function["arguments"])}]

      _invalid ->
        []
    end)
  end

  defp message_tool_calls(_calls), do: []

  defp tool_outputs(turns) do
    turns
    |> Enum.filter(&(role(&1) == "tool"))
    |> Enum.map(fn message ->
      %ToolOutput{
        call_id: text(message["tool_call_id"]),
        output: %{"content" => content_text(message)}
      }
    end)
    |> Enum.reject(&(&1.call_id == ""))
  end

  defp tool_definitions(tools) when is_list(tools) do
    Enum.flat_map(tools, fn
      %{"function" => %{"name" => name} = function} when is_binary(name) ->
        [
          %ToolDefinition{
            name: name,
            description: text(function["description"]),
            input_schema: Map.get(function, "parameters", %{}),
            strict: false
          }
        ]

      _ ->
        []
    end)
  end

  defp tool_definitions(_), do: []

  # ── run + translate ─────────────────────────────────────────────────────

  defp run(conn, grant, model, request) do
    parent = self()

    # The provider pushes events synchronously; capture them to this process's
    # mailbox and drain in order once the call returns.
    result = model.adapter.stream(request, fn event -> send(parent, {:proxy_event, event}) end)
    events = drain_events([])

    case result do
      :ok ->
        # What answered is read back off the response, never assumed from the
        # request: a gateway lane configured with fallback models can serve a
        # call for one model with another and still return 200 (METER-001).
        served = served_model(model, events)
        usage = usage_of(events)
        _ = meter(grant, usage, served)
        record_health(model, served)

        # The effective model is attributed on the response itself — the
        # header and every chunk's `model` field — so a client renders what
        # answered, not what it assumed (PROVIDER-002).
        label = model_label(model, served)

        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-openagents-model", label)
        |> send_resp(200, sse_body(events, label))

      {:error, reason} ->
        # A failure that produced partial usage is still metered, against
        # whatever the partial response said was serving it — the tokens were
        # spent on that model whether or not the stream finished.
        usage = usage_of(events)
        if usage != %{}, do: meter(grant, usage, served_model(model, events))
        class = OpenAgents.OperationalLog.code(reason)
        status = OpenAgents.OperationalLog.status(reason)
        # What the catalog publishes about this lane follows from what it
        # actually did, not only from whether a credential is configured.
        OpenAgents.Inference.Health.record_failure(model.id, status)

        Logger.warning(
          "inference_proxy_failed code=#{class}" <>
            if(status == nil, do: "", else: " upstream_status=#{status}")
        )

        refuse(conn, {:provider_failed, class, status})
    end
  end

  defp drain_events(acc) do
    receive do
      {:proxy_event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp meter(grant, usage, _served) when usage == %{}, do: {:ok, grant}
  defp meter(grant, usage, served), do: Inference.record_usage(grant, usage, served)

  # Which model actually served this call.
  #
  # `:requested` where the response named the model the grant pins, and where a
  # lane that cannot be substituted for named nothing — such a lane gets the
  # model it asked for or an error, so silence there is not ambiguity.
  # `:unresolved` where a lane that *can* be substituted for named nothing: the
  # deployment does not know what answered, and saying the requested model
  # would be a claim it cannot support. Otherwise the name the provider gave.
  defp served_model(model, events) do
    case Enum.find_value(events, fn
           {:model_served, name} -> name
           _event -> nil
         end) do
      name when is_binary(name) ->
        case Models.fetch(name) do
          {:ok, %{id: id}} when id == model.id -> :requested
          _other_or_unserved -> name
        end

      nil ->
        if substitutable?(model.adapter), do: :unresolved, else: :requested
    end
  end

  defp substitutable?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :substitutable?, 0) and
      adapter.substitutable?()
  end

  # Health is a claim about a lane, so it follows the lane that answered.
  #
  # A fallback that rescued a call is not evidence that the requested lane is
  # working — it is evidence that it is not, which is exactly what `GET
  # /api/v1/models` availability exists to publish (#238). An unresolved
  # response records nothing at all: it says neither that the lane answered nor
  # that it failed, and health that reports what it does not know is the fault
  # being fixed rather than a smaller version of it.
  defp record_health(model, :requested), do: OpenAgents.Inference.Health.record_success(model.id)
  defp record_health(_model, :unresolved), do: :ok

  defp record_health(model, name) when is_binary(name) do
    OpenAgents.Inference.Health.record_failure(model.id, nil)

    case Models.fetch(name) do
      {:ok, %{id: id}} -> OpenAgents.Inference.Health.record_success(id)
      :error -> :ok
    end
  end

  # The name the response carries. A model the catalog serves is named as a
  # client would ask for it; one it does not is named as the provider reported
  # it; and where nothing disclosed what answered, the word `unresolved` says
  # so rather than naming a model that may not have run.
  defp model_label(model, :requested), do: model.id
  defp model_label(_model, :unresolved), do: Inference.unresolved_model()

  defp model_label(_model, name) when is_binary(name) do
    case Models.fetch(name) do
      {:ok, %{id: id}} -> id
      :error -> name
    end
  end

  defp usage_of(events) do
    Enum.reduce(events, %{}, fn
      {:usage, usage}, _acc -> usage
      _event, acc -> acc
    end)
  end

  # Translate the ordered provider events into a chat-completions SSE body.
  # Every chunk carries the effective model id, the field an OpenAI-compatible
  # parser already reads as "the model that answered".
  defp sse_body(events, model_id) do
    saw_tool_call = Enum.any?(events, &match?({:tool_call, _}, &1))
    finish_reason = if saw_tool_call, do: "tool_calls", else: "stop"

    chunks =
      events
      |> Enum.with_index()
      |> Enum.flat_map(fn {event, index} -> event_chunks(event, index) end)

    finish = [%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => finish_reason}]}]

    usage_chunk =
      case usage_of(events) do
        usage when usage == %{} -> []
        usage -> [%{"choices" => [], "usage" => wire_usage(usage)}]
      end

    frames =
      Enum.map(chunks ++ finish ++ usage_chunk, fn payload ->
        data(Map.put(payload, "model", model_id))
      end)

    IO.iodata_to_binary([frames, "data: [DONE]\n\n"])
  end

  defp event_chunks({:text_delta, text}, _index) when text != "" do
    [%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]}]
  end

  # Reasoning rides the OpenRouter chat-completions extension field —
  # `delta.reasoning` alongside `delta.content` — the shape the CLI's
  # OpenAI-compatible parser already expects from that vendor surface.
  defp event_chunks({:reasoning_delta, text}, _index) when text != "" do
    [%{"choices" => [%{"index" => 0, "delta" => %{"reasoning" => text}}]}]
  end

  defp event_chunks({:tool_call, tool_call}, index) do
    [
      %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => index,
                  "id" => tool_call.call_id,
                  "type" => "function",
                  "function" => %{
                    "name" => tool_call.name,
                    "arguments" => tool_call.raw_arguments
                  }
                }
              ]
            }
          }
        ]
      }
    ]
  end

  defp event_chunks(_event, _index), do: []

  defp wire_usage(usage) do
    input = integer(usage["input_tokens"] || usage[:input_tokens])
    output = integer(usage["output_tokens"] || usage[:output_tokens])
    total = integer(usage["total_tokens"] || usage[:total_tokens])
    cache = cache_read_tokens(usage)

    base = %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => if(total > 0, do: total, else: input + output)
    }

    if is_nil(cache) do
      base
    else
      Map.put(base, "prompt_tokens_details", %{"cached_tokens" => cache})
    end
  end

  defp cache_read_tokens(usage) do
    case usage["cache_read_input_tokens"] || usage[:cache_read_input_tokens] do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp data(payload), do: ["data: ", Jason.encode!(payload), "\n\n"]

  # ── auth + errors ───────────────────────────────────────────────────────

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> {:error, :missing_grant}
    end
  end

  defp resolve(token) do
    case Inference.resolve(token) do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refuse(conn, reason) do
    {status, error} = error_for(reason)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(%{"error" => error}))
  end

  # The model refusals name the served set, because the fix for either is to
  # ask for a model on that list.
  defp error_for({:model_not_served, requested}) do
    {422, %{"code" => "model_not_served", "requested" => requested, "served" => Models.ids()}}
  end

  defp error_for({:model_mismatch, requested, granted}) do
    {422,
     %{
       "code" => "model_mismatch",
       "requested" => requested,
       "granted" => granted,
       "served" => Models.ids()
     }}
  end

  # The failure class travels with the refusal. `OperationalLog.code/1` takes
  # only the reason's atom tag and bounds it to 64 characters, so it carries no
  # provider text, no prompt, and no credential — it is the same bounded word
  # the server logs. Withholding it left the caller with "the model provider
  # failed" and nothing to act on, which reads as the product being broken
  # rather than as a call that ran out of context or hit a rate limit.
  defp error_for({:provider_failed, class, status}) do
    body = %{"code" => "provider_failed", "reason" => class}
    {502, if(status == nil, do: body, else: Map.put(body, "upstream_status", status))}
  end

  defp error_for({:provider_failed, class}) do
    {502, %{"code" => "provider_failed", "reason" => class}}
  end

  defp error_for(reason) do
    {status, code} = status_for(reason)
    {status, %{"code" => code}}
  end

  defp status_for(:missing_grant), do: {401, "missing_grant"}
  defp status_for(:grant_not_found), do: {401, "invalid_grant"}
  defp status_for(:grant_revoked), do: {403, "grant_revoked"}
  defp status_for(:grant_expired), do: {403, "grant_expired"}
  defp status_for(:grant_exhausted), do: {429, "grant_exhausted"}
  defp status_for(:grant_budget_reached), do: {429, "grant_budget_reached"}
  defp status_for(:empty_input), do: {400, "empty_input"}
  defp status_for(:invalid_request), do: {400, "invalid_request"}
  defp status_for(:body_too_large), do: {413, "body_too_large"}
  defp status_for(:invalid_json), do: {400, "invalid_json"}
  defp status_for(:provider_failed), do: {502, "provider_failed"}
  defp status_for(:model_unavailable), do: {503, "model_unavailable"}
  defp status_for(_), do: {400, "bad_request"}

  # ── small helpers ───────────────────────────────────────────────────────

  defp role(%{"role" => role}) when is_binary(role), do: role
  defp role(_), do: "user"

  defp content_text(%{"content" => content}) when is_binary(content), do: content

  defp content_text(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp content_text(_), do: ""

  defp join_text(messages) do
    messages |> Enum.map(&content_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)
  defp integer(_), do: 0
end
