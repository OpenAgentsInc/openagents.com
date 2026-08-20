defmodule OpenAgents.TurnProviderEventsTest do
  use OpenAgents.SarahDataCase
  @moduletag :skip
  alias OpenAgents.{Conversations, Turns}
  alias OpenAgents.Conversations.ProviderStep
  alias OpenAgents.Incidents.Incident
  alias OpenAgents.Turns.TurnServer

  test "truncated provider streams retain response ID, usage, and partial text as failed" do
    turn = run_turn("truncated-events-browser", "[provider-truncated]")

    assert turn.status == "failed"
    assert turn.error_message == "Sarah could not finish that response. Please try again."

    assert {:ok, receipt} = Conversations.get_turn_receipt(turn)
    assert receipt.status == "failed"
    assert receipt.usage == %{"input_tokens" => 3, "output_tokens" => 2}

    assert [step] = Conversations.list_provider_steps(receipt)
    assert step.status == "failed"
    assert step.provider_response_id
    assert step.usage == receipt.usage
    assert step.error_code == "truncated_stream"

    assistant_message =
      OpenAgents.Repo.get!(OpenAgents.Conversations.Message, turn.assistant_message_id)

    assert assistant_message.status == "failed"
    assert assistant_message.content == "Partial provider output."
  end

  test "provider cancellation becomes a typed durable cancellation" do
    turn = run_turn("cancelled-events-browser", "[provider-cancelled]")

    assert turn.status == "cancelled"
    assert {:ok, receipt} = Conversations.get_turn_receipt(turn)
    assert receipt.status == "cancelled"
    assert receipt.usage == %{"input_tokens" => 3, "output_tokens" => 0}

    assert [
             %ProviderStep{
               status: "cancelled",
               provider_response_id: response_id,
               error_code: "cancelled"
             }
           ] = Conversations.list_provider_steps(receipt)

    assert is_binary(response_id)
  end

  test "reason_code types strings, exceptions, and 3-tuples instead of unknown" do
    assert TurnServer.reason_code("econnreset from the provider socket") == "task_exit"
    assert TurnServer.reason_code("provider_timeout") == "provider_timeout"
    assert TurnServer.reason_code(%RuntimeError{message: "boom"}) == "task_exit:RuntimeError"

    assert TurnServer.reason_code({:transport, :provider_task_exited, :monitor}) ==
             "transport:provider_task_exited"

    assert TurnServer.reason_code({:noproc, {:gen_server, :call, []}, []}) == "noproc"
    assert TurnServer.reason_code(%{__exception__: true}) == "task_exit"
    assert TurnServer.reason_code({:weird, %{secret: "x"}, :extra, :more}) == "task_exit"
    refute TurnServer.reason_code("not a code") == "unknown"
    refute TurnServer.reason_code(%RuntimeError{}) == "unknown"
    refute TurnServer.reason_code({:a, :b, :c}) == "unknown"
  end

  test "a string provider error records task_exit, not unknown, with the raw reason" do
    turn = run_turn("fail-string-browser", "[fail-string-reason]")
    incident = incident_for(turn)

    assert turn.status == "failed"
    assert turn.error_code == "task_exit"
    assert incident.code == "task_exit"
    assert incident.severity == "degraded"
    assert incident.context["reason"] =~ "econnreset"
    refute incident.code == "unknown"
  end

  test "a code-shaped string is kept as the durable code" do
    turn = run_turn("fail-code-string-browser", "[fail-code-string]")
    incident = incident_for(turn)

    assert turn.error_code == "provider_timeout"
    assert incident.code == "provider_timeout"
    assert incident.severity == "degraded"
    refute incident.code == "unknown"
  end

  test "an exception provider error records task_exit:ExceptionName" do
    turn = run_turn("fail-exception-browser", "[fail-exception-reason]")
    incident = incident_for(turn)

    assert turn.status == "failed"
    assert turn.error_code == "task_exit:RuntimeError"
    assert incident.code == "task_exit:RuntimeError"
    assert incident.severity == "degraded"
    assert incident.context["reason"] =~ "RuntimeError"
    refute incident.code == "unknown"
  end

  test "a 3-tuple provider error records the family:detail code" do
    turn = run_turn("fail-triple-browser", "[fail-triple-reason]")
    incident = incident_for(turn)

    assert turn.status == "failed"
    assert turn.error_code == "transport"
    assert incident.code == "transport:provider_task_exited"
    assert incident.severity == "degraded"
    assert incident.context["reason"] =~ "provider_task_exited"
    refute incident.code == "unknown"
  end

  defp incident_for(turn) do
    Repo.get_by!(Incident, correlation_ref: turn.id)
  end

  defp run_turn(browser_key, prompt) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    assert {:ok, records} = Conversations.create_turn(conversation, prompt)
    assert {:ok, pid} = Turns.start(records.turn.id)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    Conversations.get_turn!(records.turn.id)
  end
end
