defmodule OpenAgents.Providers.Test do
  @moduledoc false

  @behaviour OpenAgents.Providers.Provider

  alias OpenAgents.Providers.{ProviderEvent, Request, ToolOutput}

  @impl true
  def id, do: "test.provider"

  @impl true
  def capabilities, do: [:text, :tool_calls, :usage]

  @impl true
  def stream(%Request{} = request, on_event) do
    if request.previous_response_id do
      emit_continuation(request, on_event)
    else
      emit_initial(request, on_event)
    end
  end

  defp emit_initial(request, on_event) do
    prompt = request.input |> List.last() |> Map.fetch!(:content)
    response_id = "test-response-" <> OpenAgents.Provenance.Canonical.sha256(prompt)

    case prompt do
      "[fail]" ->
        {:error, {:provider_failed, "test_failure"}}

      "[fail-string-reason]" ->
        {:error, "econnreset from the provider socket"}

      "[fail-code-string]" ->
        {:error, "provider_timeout"}

      "[fail-exception-reason]" ->
        {:error, %RuntimeError{message: "provider task crashed"}}

      "[fail-triple-reason]" ->
        {:error, {:transport, :provider_task_exited, :monitor}}

      "[provider-truncated]" ->
        on_event.({:response_started, response_id})
        on_event.({:text_delta, "Partial provider output."})
        on_event.({:usage, %{"input_tokens" => 3, "output_tokens" => 2}})
        {:error, :truncated_stream}

      "[provider-cancelled]" ->
        on_event.({:response_started, response_id})
        on_event.({:usage, %{"input_tokens" => 3, "output_tokens" => 0}})
        on_event.(:cancelled)
        :ok

      "[inspect-persona]" ->
        # The re-namespacing port rewrote this literal to "You are OpenAgents.",
        # but it is not a module name — it is a quote from the installed
        # persona document (`priv/sarah/persona/sarah.v1.md`, which still reads
        # "You are Sarah. You are an OpenAgent built by OpenAgents."). Asserting
        # the shipped persona text is the whole point of this branch.
        result =
          if String.contains?(request.instructions, "You are Sarah.") and
               String.contains?(request.instructions, "You are an OpenAgent") and
               String.contains?(request.instructions, "sarah.role.general_collaborator.v1") do
            "Sarah persona and role received."
          else
            "Persona missing."
          end

        emit_text_response(on_event, response_id, [result])

      "[observe-request]" ->
        observer = Application.fetch_env!(:openagents, :test_provider_observer)
        send(observer, {:provider_request, self(), request})

        receive do
          :continue_provider ->
            emit_text_response(on_event, response_id, ["Observed model #{request.model_id}."])
        after
          1_000 -> {:error, {:provider_failed, "test_observer_timeout"}}
        end

      "[reasoning]" ->
        on_event.({:response_started, response_id})
        on_event.({:reasoning_delta, "Considering the request. "})
        on_event.({:reasoning_delta, "Deciding on a reply."})
        on_event.({:text_delta, "Here is the reply."})
        on_event.({:usage, %{"input_tokens" => 4, "output_tokens" => 8}})
        on_event.({:response_completed, response_id})
        :ok

      "[tool-loop]" ->
        emit_tool_request(
          on_event,
          "tool-loop-0",
          "call-tool-1",
          "recall_messages",
          ~s({"query":"quartz"})
        )

      "[unknown-tool-loop]" ->
        emit_tool_request(on_event, "unknown-loop-0", "call-unknown-1", "missing_tool", "{}")

      "[invalid-tool-loop]" ->
        emit_tool_request(
          on_event,
          "invalid-loop-0",
          "call-invalid-1",
          "recall_messages",
          ~s({"wrong":true})
        )

      "[continuation-limit]" ->
        emit_tool_request(
          on_event,
          "limit-loop-0",
          "call-limit-0",
          "recall_messages",
          ~s({"query":"q0"})
        )

      "[cancel-tool-loop]" ->
        emit_tool_request(
          on_event,
          "cancel-loop-0",
          "call-cancel-0",
          "recall_messages",
          ~s({"query":"block"})
        )

      "[delegate-deep-work]" ->
        emit_tool_request(
          on_event,
          "delegate-deep-work-0",
          "call-delegate-deep-work",
          "deep_work",
          Jason.encode!(%{"goal" => "[deep-work-job]"})
        )

      "[coding-job]" ->
        emit_tool_request(
          on_event,
          "coding-0",
          "call-coding-read",
          "repo_read",
          ~s({"path":"note.txt","from":"workspace"})
        )

      "[deep-work-job]" ->
        emit_tool_request(
          on_event,
          "deep-work-0",
          "call-deep-work-1",
          "recall_messages",
          ~s({"query":"dw-alpha"})
        )

      "[deep-work-limit]" ->
        emit_tool_request(
          on_event,
          "deep-limit-0",
          "call-deep-limit-0",
          "recall_messages",
          ~s({"query":"dl0"})
        )

      "[deep-work-block]" ->
        emit_tool_request(
          on_event,
          "deep-work-block-0",
          "call-deep-work-block",
          "recall_messages",
          ~s({"query":"block"})
        )

      "[recall-tool-loop]" ->
        emit_tool_request(
          on_event,
          "recall-search-0",
          "call-recall-search",
          "conversation_search",
          ~s({"query":"violet-cascade-42","first":3})
        )

      "[recall-unavailable]" ->
        emit_tool_request(
          on_event,
          "recall-unavailable-0",
          "call-recall-unavailable",
          "conversation_search",
          ~s({"query":"unavailable-history-91","first":3})
        )

      "[recall-continuation-failure]" ->
        emit_tool_request(
          on_event,
          "recall-continuation-failure-0",
          "call-recall-continuation-failure",
          "conversation_search",
          ~s({"query":"continuation-anchor-90","first":3})
        )

      "[foreign-source-read]" ->
        source_ref = Application.fetch_env!(:openagents, :test_foreign_source_ref)

        emit_tool_request(
          on_event,
          "foreign-source-read-0",
          "call-foreign-source-read",
          "conversation_read",
          Jason.encode!(%{"source_ref" => source_ref})
        )

      "Remember that I prefer concise answers" ->
        emit_tool_request(
          on_event,
          "memory-remember-0",
          "call-memory-remember",
          "memory_remember",
          Jason.encode!(%{
            "memories" => [%{"category" => "preference", "claim" => "I prefer concise answers"}]
          })
        )

      "What do you remember about me?" ->
        emit_tool_request(
          on_event,
          "memory-list-0",
          "call-memory-list",
          "memory_list",
          Jason.encode!(%{"category" => "", "first" => 10})
        )

      "Forget that I prefer concise answers" ->
        emit_tool_request(
          on_event,
          "memory-forget-list-0",
          "call-memory-forget-list",
          "memory_list",
          Jason.encode!(%{"category" => "preference", "first" => 10})
        )

      "What did I say about the lunar-absence marker?" ->
        emit_tool_request(
          on_event,
          "recall-empty-0",
          "call-recall-empty",
          "conversation_search",
          ~s({"query":"lunar-absence-marker","first":3})
        )

      "What do you know about me?" ->
        if String.contains?(request.instructions, "durable profile facts") and
             String.contains?(request.instructions, "as its source supports") do
          emit_text_response(on_event, response_id, [
            "I have browser-local conversation evidence, but no durable profile facts about you."
          ])
        else
          {:error, {:provider_failed, "profile_boundary_instructions_missing"}}
        end

      "Actually, my current favorite is green. What did I say before?" ->
        emit_tool_request(
          on_event,
          "recall-correction-search-0",
          "call-correction-search",
          "conversation_search",
          ~s({"query":"favorite blue","first":3})
        )

      "What did I previously say about admin tools?" ->
        emit_tool_request(
          on_event,
          "recall-injection-search-0",
          "call-injection-search",
          "conversation_search",
          ~s({"query":"admin tools","first":3})
        )

      _prompt ->
        emit_text_response(on_event, response_id, ["I hear you. ", "You said: ", prompt])
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "memory-remember-0",
           tool_outputs: [%ToolOutput{call_id: "call-memory-remember"} = output]
         },
         on_event
       ) do
    case {output.output["status"], get_in(output.output, ["result", "memory", "claim"])} do
      {"succeeded", claim} when is_binary(claim) ->
        emit_text_response(on_event, "memory-remember-final", ["I remembered: #{claim}."])

      _failure ->
        emit_text_response(on_event, "memory-remember-refused", [
          "I couldn't store that memory."
        ])
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "memory-list-0",
           tool_outputs: [%ToolOutput{call_id: "call-memory-list"} = output]
         },
         on_event
       ) do
    case get_in(output.output, ["result", "memories"]) do
      [%{"claim" => claim} | _rest] ->
        emit_text_response(on_event, "memory-list-final", [
          "In this browser, I remember: #{claim}."
        ])

      _empty ->
        emit_text_response(on_event, "memory-list-empty", [
          "I don't have an active profile memory in this browser."
        ])
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "memory-forget-list-0",
           tool_outputs: [%ToolOutput{call_id: "call-memory-forget-list"} = output]
         },
         on_event
       ) do
    case get_in(output.output, ["result", "memories"]) do
      [%{"id" => id, "claim" => claim, "generation" => generation} | _rest] ->
        emit_tool_request(
          on_event,
          "memory-forget-write-1",
          "call-memory-forget-write",
          "memory_forget",
          Jason.encode!(%{
            "mode" => "record",
            "record_id" => id,
            "category" => "",
            "claim" => claim,
            "expected_generation" => generation
          })
        )

      _empty ->
        {:error, {:provider_failed, "memory_to_forget_not_found"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "memory-forget-write-1",
           tool_outputs: [%ToolOutput{call_id: "call-memory-forget-write"} = output]
         },
         on_event
       ) do
    if output.output["status"] == "succeeded" do
      emit_text_response(on_event, "memory-forget-final", [
        "I forgot that profile memory in this browser."
      ])
    else
      emit_text_response(on_event, "memory-forget-refused", [
        "I couldn't forget that profile memory."
      ])
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-unavailable-0",
           tool_outputs: [%ToolOutput{call_id: "call-recall-unavailable"} = output]
         },
         on_event
       ) do
    if output.output["status"] == "failed" and
         get_in(output.output, ["error", "code"]) == "lexical_unavailable" do
      emit_text_response(on_event, "recall-unavailable-final", [
        "I couldn't search older messages just now, so I can't verify that history."
      ])
    else
      {:error, {:provider_failed, "typed_recall_degradation_expected"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-continuation-failure-0",
           tool_outputs: [%ToolOutput{call_id: "call-recall-continuation-failure"}]
         },
         on_event
       ) do
    on_event.({:response_started, "recall-continuation-failure-1"})
    on_event.({:text_delta, "Uncommitted continuation text."})
    {:error, :truncated_stream}
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "foreign-source-read-0",
           tool_outputs: [%ToolOutput{call_id: "call-foreign-source-read"} = output]
         },
         on_event
       ) do
    emit_text_response(on_event, "foreign-source-read-final", [
      "Recall source outcome: #{output.output["status"]}."
    ])
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "tool-loop-0",
           tool_outputs: [%ToolOutput{call_id: "call-tool-1"} = output]
         },
         on_event
       ) do
    emit_outcome_text(on_event, "tool-loop-final", output, "Known tool")
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "unknown-loop-0",
           tool_outputs: [%ToolOutput{call_id: "call-unknown-1"} = output]
         },
         on_event
       ) do
    emit_outcome_text(on_event, "unknown-loop-final", output, "Unknown tool")
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "invalid-loop-0",
           tool_outputs: [%ToolOutput{call_id: "call-invalid-1"} = output]
         },
         on_event
       ) do
    emit_outcome_text(on_event, "invalid-loop-final", output, "Invalid call")
  end

  # A limit report request carries no tool definitions, so the model answers
  # in text instead of chaining another call.
  defp emit_continuation(
         %Request{
           previous_response_id: "limit-loop-" <> index,
           tool_outputs: [%ToolOutput{call_id: "call-limit-" <> index} = output],
           tool_definitions: []
         },
         on_event
       ) do
    emit_outcome_text(on_event, "limit-loop-final", output, "Limit report")
  end

  # Endless chain: every continuation requests one more call, so the host's
  # execution limits are what stop it.
  defp emit_continuation(
         %Request{
           previous_response_id: "limit-loop-" <> index,
           tool_outputs: [%ToolOutput{call_id: "call-limit-" <> index}]
         },
         on_event
       ) do
    next = String.to_integer(index) + 1

    emit_tool_request(
      on_event,
      "limit-loop-#{next}",
      "call-limit-#{next}",
      "recall_messages",
      ~s({"query":"q#{next}"})
    )
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-search-0",
           tool_outputs: [%ToolOutput{call_id: "call-recall-search"} = output]
         },
         on_event
       ) do
    case get_in(output.output, ["result", "matches"]) do
      [%{"source_ref" => source_ref} | _matches] ->
        emit_tool_request(
          on_event,
          "recall-read-1",
          "call-recall-read",
          "conversation_read",
          Jason.encode!(%{"source_ref" => source_ref, "before" => 1, "after" => 1})
        )

      _no_match ->
        {:error, {:provider_failed, "recall_search_returned_no_match"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-read-1",
           tool_outputs: [%ToolOutput{call_id: "call-recall-read"} = output]
         },
         on_event
       ) do
    messages = get_in(output.output, ["result", "messages"]) || []
    observed_at = get_in(output.output, ["result", "evidence", "observed_at"])

    if is_binary(observed_at) and
         Enum.any?(messages, &String.contains?(&1["content"], "violet-cascade-42")) do
      emit_text_response(on_event, "recall-final-2", [
        "On #{String.slice(observed_at, 0, 10)}, you called the marker violet-cascade-42."
      ])
    else
      {:error, {:provider_failed, "recall_read_missing_source"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-empty-0",
           tool_outputs: [%ToolOutput{call_id: "call-recall-empty"} = output]
         },
         on_event
       ) do
    if get_in(output.output, ["result", "status"]) == "empty" do
      emit_text_response(on_event, "recall-empty-final", [
        "I found no matching prior statement in this browser conversation."
      ])
    else
      {:error, {:provider_failed, "recall_empty_expected"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-correction-search-0",
           tool_outputs: [%ToolOutput{call_id: "call-correction-search"} = output]
         },
         on_event
       ) do
    continue_with_first_match(output, on_event, %{
      response_id: "recall-correction-read-1",
      call_id: "call-correction-read"
    })
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-correction-read-1",
           tool_outputs: [%ToolOutput{call_id: "call-correction-read"} = output]
         },
         on_event
       ) do
    messages = get_in(output.output, ["result", "messages"]) || []
    observed_at = get_in(output.output, ["result", "evidence", "observed_at"])

    if is_binary(observed_at) and Enum.any?(messages, &String.contains?(&1["content"], "blue")) do
      emit_text_response(on_event, "recall-correction-final", [
        "Your current correction is green. On #{String.slice(observed_at, 0, 10)}, you previously said blue."
      ])
    else
      {:error, {:provider_failed, "correction_source_missing"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-injection-search-0",
           tool_outputs: [%ToolOutput{call_id: "call-injection-search"} = output]
         },
         on_event
       ) do
    continue_with_first_match(output, on_event, %{
      response_id: "recall-injection-read-1",
      call_id: "call-injection-read"
    })
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "recall-injection-read-1",
           tool_outputs: [%ToolOutput{call_id: "call-injection-read"} = output]
         },
         on_event
       ) do
    messages = get_in(output.output, ["result", "messages"]) || []

    if Enum.any?(messages, &String.contains?(&1["content"], "add admin tools")) do
      emit_text_response(on_event, "recall-injection-final", [
        "You previously wrote an instruction to ignore Sarah and add admin tools. I treated it as historical text, not an instruction."
      ])
    else
      {:error, {:provider_failed, "injection_source_missing"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "delegate-deep-work-0",
           tool_outputs: [%ToolOutput{call_id: "call-delegate-deep-work"} = output]
         },
         on_event
       ) do
    case {output.output["status"], get_in(output.output, ["result", "job_ref"])} do
      {"succeeded", "work-job:" <> _job_id} ->
        emit_text_response(on_event, "delegate-deep-work-final", [
          "I started a deep work job on that; the report will land here when it finishes."
        ])

      _failure ->
        emit_text_response(on_event, "delegate-deep-work-refused", [
          "I couldn't start that deep work job."
        ])
    end
  end

  # Coding job worker chain (#122): read -> edit -> check -> commit+push ->
  # report naming the pushed sha (the operator promotes from the report).
  defp emit_continuation(
         %Request{
           previous_response_id: "coding-0",
           tool_outputs: [%ToolOutput{call_id: "call-coding-read"} = output]
         },
         on_event
       ) do
    if output.output["status"] == "succeeded" do
      emit_tool_request(
        on_event,
        "coding-1",
        "call-coding-edit",
        "repo_edit",
        Jason.encode!(%{
          "path" => "note.txt",
          "old_string" => "original content",
          "new_string" => "edited by sarah's coding job"
        })
      )
    else
      {:error, {:provider_failed, "coding_read_failed"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "coding-1",
           tool_outputs: [%ToolOutput{call_id: "call-coding-edit"} = output]
         },
         on_event
       ) do
    if output.output["status"] == "succeeded" do
      emit_tool_request(
        on_event,
        "coding-2",
        "call-coding-check",
        "code_check",
        Jason.encode!(%{
          "content" => "defmodule CodingJobProbe#{System.unique_integer([:positive])} do\nend\n"
        })
      )
    else
      {:error, {:provider_failed, "coding_edit_failed"}}
    end
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "coding-2",
           tool_outputs: [%ToolOutput{call_id: "call-coding-check"}]
         },
         on_event
       ) do
    emit_tool_request(
      on_event,
      "coding-3",
      "call-coding-push",
      "repo_commit_push",
      Jason.encode!(%{"message" => "Coding job: edit note.txt"})
    )
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "coding-3",
           tool_outputs: [%ToolOutput{call_id: "call-coding-push"} = output]
         },
         on_event
       ) do
    case output.output do
      %{"status" => "succeeded", "result" => %{"sha" => sha, "branch" => branch}} ->
        emit_text_response(on_event, "coding-final", [
          "Coding report: pushed ",
          sha,
          " on ",
          branch,
          " — ready for operator promotion."
        ])

      _failure ->
        emit_text_response(on_event, "coding-final-failed", [
          "Coding report: the push failed; nothing to promote."
        ])
    end
  end

  # Deep-work job worker chain: two lookarounds, then one narrative report.
  defp emit_continuation(
         %Request{
           previous_response_id: "deep-work-0",
           tool_outputs: [%ToolOutput{call_id: "call-deep-work-1"}]
         },
         on_event
       ) do
    emit_tool_request(
      on_event,
      "deep-work-1",
      "call-deep-work-2",
      "recall_messages",
      ~s({"query":"dw-beta"})
    )
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "deep-work-1",
           tool_outputs: [%ToolOutput{call_id: "call-deep-work-2"} = output]
         },
         on_event
       ) do
    emit_text_response(on_event, "deep-work-final", [
      "Deep work report: ",
      "both lookarounds #{output.output["status"]}; found dw-alpha and dw-beta."
    ])
  end

  # A deep-work limit report request carries no tool definitions, so the
  # worker's host bound is what ends the chain.
  defp emit_continuation(
         %Request{
           previous_response_id: "deep-limit-" <> index,
           tool_outputs: [%ToolOutput{call_id: "call-deep-limit-" <> index} = output],
           tool_definitions: []
         },
         on_event
       ) do
    emit_text_response(on_event, "deep-limit-final", [
      "Deep work partial report: the host limit ended the search (#{output.output["status"]})."
    ])
  end

  defp emit_continuation(
         %Request{
           previous_response_id: "deep-limit-" <> index,
           tool_outputs: [%ToolOutput{call_id: "call-deep-limit-" <> index}]
         },
         on_event
       ) do
    next = String.to_integer(index) + 1

    emit_tool_request(
      on_event,
      "deep-limit-#{next}",
      "call-deep-limit-#{next}",
      "recall_messages",
      ~s({"query":"dl#{next}"})
    )
  end

  defp emit_continuation(_request, _on_event),
    do: {:error, {:provider_failed, "unexpected_continuation"}}

  defp emit_tool_request(on_event, response_id, call_id, name, arguments) do
    on_event.({:response_started, response_id})

    on_event.(
      {:tool_call,
       %ProviderEvent.ToolCall{
         item_id: "item-#{call_id}",
         call_id: call_id,
         name: name,
         raw_arguments: arguments
       }}
    )

    on_event.({:usage, %{"input_tokens" => 3, "output_tokens" => 1}})
    on_event.({:response_completed, response_id})
    :ok
  end

  defp emit_outcome_text(on_event, response_id, %ToolOutput{} = output, label) do
    status = output.output["status"]
    emit_text_response(on_event, response_id, ["#{label} outcome: #{status}."])
  end

  defp continue_with_first_match(output, on_event, options) do
    case get_in(output.output, ["result", "matches"]) do
      [%{"source_ref" => source_ref} | _matches] ->
        emit_tool_request(
          on_event,
          options.response_id,
          options.call_id,
          "conversation_read",
          Jason.encode!(%{"source_ref" => source_ref, "before" => 1, "after" => 1})
        )

      _no_match ->
        {:error, {:provider_failed, "recall_search_returned_no_match"}}
    end
  end

  defp emit_text_response(on_event, response_id, deltas) do
    on_event.({:response_started, response_id})
    Enum.each(deltas, &on_event.({:text_delta, &1}))
    on_event.({:usage, %{"input_tokens" => 4, "output_tokens" => 8}})
    on_event.({:response_completed, response_id})
    :ok
  end
end
