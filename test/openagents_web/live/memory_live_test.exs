defmodule OpenAgentsWeb.MemoryLiveTest do
  @moduledoc """
  `/memory` is a page, not a panel inside the conversation.

  It was the latter: a sidebar row swapped the transcript out for it, which
  made it reachable only from chat and gave it no address. These tests visit
  it directly, which is what a reader now does.

  What they hold is the account boundary and the exactness of destructive
  controls: memory is a claim a system makes about a person, so correction
  must supersede rather than overwrite, and "forget" must state which of its
  three scopes it means before it acts.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Message
  alias OpenAgents.ProfileMemory

  test "memory surface is accessible, exact, source-dated, and account-scoped", %{conn: conn} do
    token = "memory-surface-browser-credential-000000000000000"
    %{record: record, source: source} = create_profile_memory(token, "I prefer concise answers")
    conn = log_in_github_user(conn, token)
    assert {:ok, view, _html} = live(conn, ~p"/memory")

    html = render(view)

    assert html =~ ~s(id="memory-manager")
    assert html =~ ~s(aria-labelledby="memory-heading")
    assert html =~ "Memory in your account"
    assert html =~ "follow your authenticated Sarah account across browsers"
    assert html =~ "I prefer concise answers"
    assert html =~ "OWNER_STATEMENT" or html =~ "owner_statement"
    assert html =~ Date.to_iso8601(DateTime.to_date(source.inserted_at))
    assert has_element?(view, "#memory-record-#{record.id}[data-status=active]")
    assert has_element?(view, "#memory-claim-#{record.id}")
    assert has_element?(view, "#forget-category-#{record.id}")
    assert has_element?(view, "#export-memory[href='/memory/export']")
    assert has_element?(view, "#delete-data-form label[for='privacy_confirmation']")
    assert has_element?(view, "#delete-data-form input#privacy_confirmation[type='text']")
    assert has_element?(view, "#delete-data-form button#delete-all-data[type='submit']")
    refute has_element?(view, "#message-form")

    # The conversation is a different page now, reached from the sidebar.
    refute has_element?(view, "#message-form")
  end

  test "correction preserves supersession and reconciles another open tab", %{conn: conn} do
    token = "memory-correction-browser-credential-0000000000000"
    %{record: record} = create_profile_memory(token, "I prefer concise answers")
    user = github_user(token)
    conn = log_in_github_user(conn, token)
    assert {:ok, first, _html} = live(conn, ~p"/memory")
    assert {:ok, second, _html} = live(conn, ~p"/memory")

    first
    |> form("#memory-record-#{record.id} form", %{"claim" => "I prefer concise, direct answers"})
    |> render_submit()

    assert eventually(fn ->
             html = render(second)

             html =~ "I prefer concise, direct answers" and
               has_element?(second, "#memory-record-#{record.id}[data-status=superseded]")
           end)

    conversation = Conversations.get_conversation_for_user(user)
    owner = Conversations.get_conversation_owner!(conversation)
    assert {:ok, [replacement]} = ProfileMemory.list_current(owner)
    assert replacement.claim == "I prefer concise, direct answers"
    assert replacement.supersedes_record_id == record.id
  end

  test "forget requires inline confirmation and disappears from future snapshots", %{conn: conn} do
    token = "memory-forget-ui-browser-credential-000000000000"
    %{record: record} = create_profile_memory(token, "I prefer concise answers")
    user = github_user(token)
    conn = log_in_github_user(conn, token)
    assert {:ok, view, _html} = live(conn, ~p"/memory")

    view |> element("#forget-record-#{record.id}") |> render_click()
    assert has_element?(view, "#memory-confirmation")
    assert render(view) =~ "Confirm destructive action"

    view |> element("#cancel-memory-action") |> render_click()
    refute has_element?(view, "#memory-confirmation")
    assert has_element?(view, "#memory-record-#{record.id}[data-status=active]")

    view |> element("#forget-record-#{record.id}") |> render_click()
    view |> element("#confirm-memory-forget") |> render_click()

    assert has_element?(view, "#memory-record-#{record.id}[data-status=forgotten]")
    assert render(view) =~ "Forgot 1 memory record(s) in this account."

    conversation = Conversations.get_conversation_for_user(user)
    owner = Conversations.get_conversation_owner!(conversation)
    assert {:ok, snapshot} = ProfileMemory.capture_snapshot(owner)
    assert {:ok, []} = ProfileMemory.list_active(owner, snapshot)
  end

  test "category and whole-account controls confirm their exact destructive breadth", %{
    conn: conn
  } do
    token = "memory-bulk-forget-browser-credential-00000000000"
    %{record: preference} = create_profile_memory(token, "I prefer concise answers")
    %{record: project} = create_profile_memory(token, "My project is One", "project")
    user = github_user(token)
    conn = log_in_github_user(conn, token)
    assert {:ok, view, _html} = live(conn, ~p"/memory")

    view |> element("#forget-category-#{project.id}") |> render_click()
    assert render(view) =~ "Forget every active project memory in this account?"
    view |> element("#confirm-memory-forget") |> render_click()
    assert has_element?(view, "#memory-record-#{project.id}[data-status=forgotten]")
    assert has_element?(view, "#memory-record-#{preference.id}[data-status=active]")

    view |> element("#forget-all-memory") |> render_click()
    assert render(view) =~ "Forget every active profile memory in this account?"
    view |> element("#confirm-memory-forget") |> render_click()
    assert has_element?(view, "#memory-record-#{preference.id}[data-status=forgotten]")

    conversation = Conversations.get_conversation_for_user(user)
    owner = Conversations.get_conversation_owner!(conversation)
    assert {:ok, []} = ProfileMemory.list_current(owner)
  end

  defp create_profile_memory(token, claim, category \\ "preference") do
    assert {:ok, conversation} = Conversations.ensure_conversation(github_user(token))
    owner = Conversations.get_conversation_owner!(conversation)

    source =
      OpenAgents.Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: "user",
        content: "Remember that #{claim}",
        status: "complete"
      })

    assert {:ok, %{record: record}} =
             ProfileMemory.remember_explicit(owner, %{
               category: category,
               claim: claim,
               creator: "user_explicit",
               provenance: %{
                 "operation" => "test_explicit_memory",
                 "tool_payload" => "INTERNAL_TEST_PAYLOAD"
               },
               sources: [%{source_ref: "message:#{source.id}", kind: "owner_statement"}]
             })

    %{record: record, source: source, owner: owner}
  end

  # A correction lands in another tab through PubSub, so the second view is
  # polled rather than assumed to have caught up.
  defp eventually(assertion, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(assertion, deadline)
  end

  defp do_eventually(assertion, deadline) do
    if assertion.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
          _message -> :ok
        after
          10 -> :ok
        end

        do_eventually(assertion, deadline)
      end
    end
  end
end
