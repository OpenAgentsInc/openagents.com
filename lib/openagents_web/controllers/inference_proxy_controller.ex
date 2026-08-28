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
  request. One lane can substitute, and only where nothing named a model: the
  Vercel AI Gateway is configured with a fallback model list, and unnamed-model
  selection attaches it, so a call that asked for whatever this deployment
  serves can be answered by `zai/glm-5.3` and still return 200. A grant that
  named a model is a pin. That call omits the fallback list and keeps the
  Vertex `order` pin; if the gateway still substitutes, the proxy does not
  return 200 (PROVIDER-002). The serving model therefore decides three things
  — the name attributed on the response, the lane whose health is recorded,
  and the rate table the usage record is priced against (METER-001). A
  substitutable unnamed call whose response discloses no model is attributed
  `unresolved` and priced at nothing, because naming the requested model would
  be a claim the deployment cannot support.

  ## The stream is flushed as it happens

  Provider events are written to the client one chunk at a time as the adapter
  emits them, so a client renders reasoning and text tokens while the vendor is
  still writing them (#263). The provider still streams from its vendor
  internally; this hop no longer collects the events and answers after the
  fact. The cost is honest and accepted: committing to a chunked response
  means a provider failure can no longer be a clean non-200 status, so a
  failure after the stream opened arrives as a terminal `provider_failed`
  frame in the stream body, carrying the same bounded reason class the JSON
  refusal carried (`error.reason`, with `error.upstream_status` when known) —
  never raw provider detail.
  """

  use OpenAgentsWeb, :controller

  require Logger

  alias OpenAgents.Analytics
  alias OpenAgents.Inference
  alias OpenAgents.Inference.{Models, Pricing}
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
    if unnamed_selection?(grant, body) do
      {:ok, Models.select()}
    else
      case Models.fetch(grant.model_id) do
        {:ok, model} -> {:ok, model}
        :error -> {:error, :model_unavailable}
      end
    end
  end

  # Neither the mint nor the call named a model: the server selects, and the
  # gateway may still try its fallback list. A grant minted for a model other
  # than the default, or a body that names one, is a pin (#258).
  defp unnamed_selection?(grant, body) do
    no_model_in_body?(body) and grant.model_id == Models.default_id()
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
    content = message_content(message)

    case {content_empty?(content), tool_calls} do
      {true, []} -> []
      {false, []} -> [%{role: role(message), content: content}]
      # An assistant turn that called tools is part of the transcript even
      # when it carried no prose: dropping it would orphan the tool outputs
      # that answer it.
      {_empty, calls} -> [%{role: role(message), content: content, tool_calls: calls}]
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

  # Per-event state rides the process dictionary of this request's own
  # process: the callback cannot rebind outer variables (the conn that carries
  # sent chunks does not survive a closure either), and the state lives and
  # dies with this one request.
  @state_events :proxy_stream_events
  @state_usage :proxy_stream_usage
  @state_served :proxy_stream_served_model
  @state_conn :proxy_stream_conn
  @state_raw_conn :proxy_stream_raw_conn
  @state_opened :proxy_stream_opened
  @state_allow_fallback :proxy_stream_allow_fallback

  defp run(conn, grant, model, request) do
    allow_fallback? = unnamed_selection?(grant, conn.body_params)
    selection = selection_properties(grant, model, request, conn.body_params)
    Analytics.capture("inference_model_selected", analytics_distinct_id(grant), selection)

    Process.put(@state_raw_conn, conn)
    Process.put(@state_allow_fallback, allow_fallback?)

    # Unnamed-model selection may still be answered by a fallback, so the
    # stream opens before the first provider event (#263). A pin waits until
    # the serving model is known: opening 200 first would make a substituted
    # grant look like a successful turn (#258).
    if allow_fallback?, do: open_stream(model)

    # The provider pushes events synchronously. Once the stream is open, each
    # event is translated and written to the client as it arrives.
    result =
      stream_adapter(model.adapter, request, &emit_event(conn, model, &1),
        allow_fallback: allow_fallback?
      )

    case result do
      :ok ->
        events = drained_events()

        # What answered is read back off the response, never assumed from the
        # request. Unnamed-model selection may still land on a fallback and
        # return 200 (METER-001). A pin must be the grant's model.
        served = served_model(model, events)
        usage = drained_usage()

        if allow_fallback? or served == :requested do
          finish_served(conn, grant, model, selection, served, usage, events)
        else
          finish_pin_violation(grant, model, selection, served, usage)
        end

      {:error, reason} ->
        events = drained_events()

        # A failure that produced partial usage is still metered, against
        # whatever the partial response said was serving it — the tokens were
        # spent on that model whether or not the stream finished.
        usage = drained_usage()
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

        Analytics.capture(
          "inference_model_failed",
          analytics_distinct_id(grant),
          Map.merge(selection, %{
            "outcome" => "provider_failed",
            "reason_code" => class,
            "upstream_status" => status,
            "usage_reported" => usage != %{}
          })
        )

        finish_provider_error(conn, class, status)
    end
  end

  defp stream_adapter(adapter, request, on_event, options) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :stream, 3) do
      adapter.stream(request, on_event, options)
    else
      adapter.stream(request, on_event)
    end
  end

  defp finish_served(conn, grant, model, selection, served, usage, events) do
    unless Process.get(@state_opened) do
      open_stream(model)
      flush_event_chunks(conn, model, events)
    end

    _ = meter(grant, usage, served)
    record_health(model, served)

    # The effective model is attributed on the response itself — the
    # header and every chunk's `model` field — so a client renders what
    # answered, not what it assumed (PROVIDER-002).
    label = model_label(model, served)

    Analytics.capture(
      "inference_model_served",
      analytics_distinct_id(grant),
      Map.merge(selection, %{
        "served_model" => label,
        "served_model_disclosed" => served != :unresolved,
        "outcome" => "served",
        "usage_reported" => usage != %{}
      })
    )

    Enum.each(sse_chunks(events, usage, label), &write_chunk(conn, &1))
    Process.get(@state_conn) || conn
  end

  defp finish_pin_violation(grant, model, selection, served, usage) do
    # Tokens were spent on the model that answered, even though the pin
    # forbids returning that as a successful turn.
    if usage != %{}, do: meter(grant, usage, served)
    OpenAgents.Inference.Health.record_failure(model.id, nil)

    served_label = model_label(model, served)

    Analytics.capture(
      "inference_model_failed",
      analytics_distinct_id(grant),
      Map.merge(selection, %{
        "outcome" => "model_substituted",
        "reason_code" => "model_substituted",
        "served_model" => served_label,
        "usage_reported" => usage != %{}
      })
    )

    refuse(Process.get(@state_raw_conn), {:model_substituted, model.id, served_label})
  end

  defp finish_provider_error(conn, class, status) do
    if Process.get(@state_opened) do
      # The 200 is already on the wire, so the failure travels as terminal
      # frames instead of a status: the same bounded class and upstream
      # status the JSON refusal would have carried, and nothing more.
      write_chunk(conn, data(%{"error" => stream_error(class, status)}))
      write_chunk(conn, "data: [DONE]\n\n")
      Process.get(@state_conn) || conn
    else
      refuse(
        Process.get(@state_raw_conn) || conn,
        {:provider_failed, class, status}
      )
    end
  end

  defp open_stream(model) do
    if Process.get(@state_opened) do
      :ok
    else
      sent =
        Process.get(@state_raw_conn)
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-openagents-model", model.id)
        |> send_chunked(200)

      Process.put(@state_conn, sent)
      Process.put(@state_opened, true)
      :ok
    end
  end

  defp stream_error(class, status) do
    body = %{"code" => "provider_failed", "reason" => class}
    if status == nil, do: body, else: Map.put(body, "upstream_status", status)
  end

  defp emit_event(conn, model, event) do
    record_event(event)
    record_disclosure(event)

    cond do
      Process.get(@state_opened) ->
        write_event_chunks(conn, model, [event])

      pin_confirmed?(model) ->
        open_stream(model)
        write_event_chunks(conn, model, Enum.reverse(Process.get(@state_events) || []))

      true ->
        :ok
    end

    :ok
  end

  defp pin_confirmed?(model) do
    Process.get(@state_allow_fallback) == true or
      served_matches_pin?(model, Process.get(@state_served))
  end

  defp served_matches_pin?(_model, nil), do: false

  defp served_matches_pin?(model, name) when is_binary(name) do
    case Models.fetch(name) do
      {:ok, %{id: id}} -> id == model.id
      :error -> name == model.id or name == model.provider_model
    end
  end

  defp write_event_chunks(conn, model, events) do
    label = chunk_model(model)

    for event <- events, payload <- event_chunks(event) do
      write_chunk(conn, data(Map.put(payload, "model", label)))
    end

    :ok
  end

  defp flush_event_chunks(conn, model, events), do: write_event_chunks(conn, model, events)

  # A fallback disclosure corrects the name on the very chunks that follow it;
  # before one arrives, every chunk names the grant's lane, exactly as the
  # pre-stream header does. METER-001/PROVIDER-002: the response says what
  # answered, not what was requested.
  defp record_disclosure({:model_served, name}) when is_binary(name) do
    case Models.fetch(name) do
      {:ok, %{id: id}} -> Process.put(@state_served, id)
      :error -> Process.put(@state_served, name)
    end

    :ok
  end

  defp record_disclosure(_event), do: :ok

  defp chunk_model(model) do
    Process.get(@state_served) || model.id
  end

  defp record_event({:usage, usage}) when is_map(usage) do
    Process.put(@state_usage, usage)
    Process.put(@state_events, [:usage | Process.get(@state_events) || []])
    :ok
  end

  defp record_event(event) do
    Process.put(@state_events, [event | Process.get(@state_events) || []])
    :ok
  end

  defp drained_events, do: Enum.reverse(Process.get(@state_events) || [])

  defp drained_usage, do: Process.get(@state_usage) || %{}

  # The latest conn always comes off the process dictionary: chunk/2 returns a
  # new conn carrying the accumulated body, so feeding each call the stale
  # closure conn would restart the body from zero, and the controller has to
  # return a conn that holds the whole response.
  defp write_chunk(conn, payload) do
    case Plug.Conn.chunk(Process.get(@state_conn) || conn, payload) do
      {:ok, sent} -> Process.put(@state_conn, sent)
      {:error, _closed} -> :ok
    end

    :ok
  end

  defp meter(grant, usage, _served) when usage == %{}, do: {:ok, grant}
  defp meter(grant, usage, served), do: Inference.record_usage(grant, usage, served)

  # This is the complete non-secret selection record for one provider call.
  # It deliberately excludes the bearer grant, prompts, instructions, and tool
  # arguments. The grant's visitor id becomes the analytics distinct id only;
  # it is not an event property.
  defp selection_properties(grant, model, request, body) do
    requested = Map.get(body, "model")
    pricing = Pricing.effective_pricing(model)
    promotion_ends_at = Pricing.promotion_ends_at(model)

    %{
      "selection_schema" => "inference_model_selection.v1",
      "selection_surface" => "inference_proxy",
      "requested_model" => requested,
      "requested_model_present" => is_binary(requested) and requested != "",
      "grant_model" => grant.model_id,
      "selected_model" => model.id,
      "provider" => Atom.to_string(model.provider),
      "provider_model" => model.provider_model,
      "pricing_id" => Pricing.pricing_id(pricing),
      "pricing_basis" => Pricing.basis_of(pricing),
      "pricing_promotion_active" =>
        Pricing.pricing_id(pricing) != Pricing.pricing_id(model.pricing),
      "pricing_promotion_ends_at" =>
        if(promotion_ends_at, do: DateTime.to_iso8601(promotion_ends_at), else: nil),
      "input_price_per_million_tokens" => pricing && pricing.input_per_million_tokens,
      "output_price_per_million_tokens" => pricing && pricing.output_per_million_tokens,
      "cached_input_price_per_million_tokens" =>
        pricing && Map.get(pricing, :cached_input_per_million_tokens),
      "model_availability" => Models.availability(model),
      "model_available" => Models.available?(model),
      "adapter_substitutable" => substitutable?(model.adapter),
      "request_model" => request.model_id,
      "max_output_tokens" => request.max_output,
      "input_message_count" => length(request.input),
      "tool_definition_count" => length(request.tool_definitions),
      "tool_output_count" => length(request.tool_outputs),
      "grant_call_count_before" => grant.call_count,
      "grant_max_calls" => grant.max_calls,
      "grant_max_total_tokens" => grant.max_total_tokens,
      "grant_max_cost_microusd" => grant.max_cost_microusd,
      "grant_has_thread_fence" => is_binary(grant.thread_id),
      "grant_has_conversation_fence" => is_binary(grant.conversation_id)
    }
  end

  defp analytics_distinct_id(grant),
    do: Analytics.distinct_id("visitor_" <> grant.owner_visitor_id)

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

  # The terminal frames a finished stream closes with: one finish_reason chunk
  # (tool_calls when the provider asked for a tool, stop otherwise) and the
  # usage chunk when the provider reported one.
  defp sse_chunks(events, usage, model_id) do
    saw_tool_call = Enum.any?(events, &match?({:tool_call, _}, &1))
    finish_reason = if saw_tool_call, do: "tool_calls", else: "stop"

    finish = [%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => finish_reason}]}]

    usage_chunk =
      case usage do
        usage when usage == %{} -> []
        usage -> [%{"choices" => [], "usage" => wire_usage(usage)}]
      end

    Enum.map(finish ++ usage_chunk, fn payload ->
      data(Map.put(payload, "model", model_id))
    end) ++ ["data: [DONE]\n\n"]
  end

  # One provider event in, its chat-completions chunk out, flushed before the
  # next event is asked for.
  defp event_chunks({:text_delta, text}) when text != "" do
    [%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]}]
  end

  # Reasoning rides the OpenRouter chat-completions extension field —
  # `delta.reasoning` alongside `delta.content` — the shape the CLI's
  # OpenAI-compatible parser already expects from that vendor surface.
  defp event_chunks({:reasoning_delta, text}) when text != "" do
    [%{"choices" => [%{"index" => 0, "delta" => %{"reasoning" => text}}]}]
  end

  defp event_chunks({:tool_call, tool_call}) do
    [
      %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
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

  defp event_chunks(_event), do: []

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

  # A pin whose provider answered with another model is not a successful turn.
  # The client named one model; attributing a fallback as 200 is the miss #258
  # closes even when PROVIDER-002 would otherwise name the substitute.
  defp error_for({:model_substituted, granted, served}) do
    {502, %{"code" => "model_substituted", "granted" => granted, "served" => served}}
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

  defp message_content(%{"content" => content}) when is_binary(content), do: content

  defp message_content(%{"content" => parts}) when is_list(parts) do
    Enum.flat_map(parts, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        [%{type: "text", text: text}]

      %{"type" => "image_url", "image_url" => %{"url" => url}}
      when is_binary(url) ->
        if inline_image?(url),
          do: [%{type: "image_url", image_url: %{url: url}}],
          else: []

      _invalid ->
        []
    end)
  end

  defp message_content(_), do: ""

  defp content_empty?(""), do: true
  defp content_empty?([]), do: true
  defp content_empty?(_content), do: false

  defp inline_image?(url) do
    String.starts_with?(url, [
      "data:image/png;base64,",
      "data:image/jpeg;base64,",
      "data:image/gif;base64,",
      "data:image/webp;base64,"
    ])
  end

  defp join_text(messages) do
    messages |> Enum.map(&content_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)
  defp integer(_), do: 0
end
