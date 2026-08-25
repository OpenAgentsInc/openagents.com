defmodule OpenAgents.Tools.ProfileMemoryToolsTest do
  use OpenAgents.DataCase

  alias OpenAgents.Conversations.{Message, Visitor}
  alias OpenAgents.Memory.Consent
  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner}
  alias OpenAgents.{Conversations, ProfileMemory, Repo}

  @tools [
    OpenAgents.Tools.MemoryList,
    OpenAgents.Tools.MemorySearch,
    OpenAgents.Tools.MemoryRemember,
    OpenAgents.Tools.MemoryCorrect,
    OpenAgents.Tools.MemoryForget
  ]

  setup do
    assert {:ok, snapshot} = Registry.build(@tools)
    %{snapshot: snapshot}
  end

  test "first-party UI evidence remains host-only and exact" do
    consent = %{
      "kind" => "first_party_ui",
      "operation" => "remember",
      "claim" => "My project is One"
    }

    assert {:ok, %{kind: "first_party_ui"}} =
             Consent.remember("UI action", "My project is One", consent)

    assert {:error, :memory_consent_mismatch} =
             Consent.remember("UI action", "My project is Two", consent)
  end

  test "natural all-memory forget phrasings are explicit while partial requests stay refused" do
    accepted = [
      "Forget everything you remember about me.",
      "Please forget everything you've stored about me.",
      "Please forget everything you’ve saved about me.",
      "Forget all memories about me",
      "Forget everything in this browser",
      "Delete everything you know about me."
    ]

    for phrase <- accepted do
      assert {:ok, %{kind: "current_message", claim: "all"}} =
               Consent.forget(phrase, "all", "all"),
             "expected acceptance: #{phrase}"
    end

    refused = [
      "Forget everything about my job.",
      "Forget my name.",
      "Maybe you should forget some things."
    ]

    for phrase <- refused do
      assert {:error, :memory_consent_required} = Consent.forget(phrase, "all", "all"),
             "expected refusal: #{phrase}"
    end
  end

  test "record forget accepts an explicit qualified subject without widening authority", %{
    snapshot: snapshot
  } do
    assert {:ok, %{kind: "current_message"}} =
             Consent.forget(
               "Forget my permanent staging qualification shape and remove that lasting profile preference.",
               "record",
               "The user's permanent staging qualification shape is square"
             )

    assert {:error, :memory_consent_mismatch} =
             Consent.forget(
               "Forget my permanent staging qualification shape and remove that lasting profile preference.",
               "record",
               "The user's permanent deployment preference is canary"
             )

    assert {:error, :memory_consent_mismatch} =
             Consent.forget(
               "Forget my name and remove that memory.",
               "record",
               "My name is Chris"
             )

    scope = browser("memory-qualified-forget")

    record =
      remember(
        snapshot,
        scope,
        "preference",
        "The user's permanent staging qualification shape is square"
      )

    message =
      user_message(
        scope.conversation,
        "Forget my permanent staging qualification shape and remove that lasting profile preference."
      )

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("memory_forget", %{
                 "mode" => "record",
                 "record_id" => record.id,
                 "category" => "preference",
                 "claim" => record.claim,
                 "expected_generation" => record.generation
               }),
               context(scope, message)
             )

    assert outcome["result"]["receipt"]["disposition"] == "forgotten"
    assert {:ok, []} = ProfileMemory.list_current(scope.owner)
  end

  test "secret-bearing explicit consent is still refused without echo or storage", %{
    snapshot: snapshot
  } do
    scope = browser("memory-secret-refusal")
    fake_secret = "sk-" <> "proj-" <> String.duplicate("A", 64)
    claim = "my test token is #{fake_secret}"
    message = user_message(scope.conversation, "Remember that #{claim}")

    assert {:ok, refused} =
             Runner.run(
               snapshot,
               call("memory_remember", %{
                 "memories" => [%{"category" => "other", "claim" => claim}]
               }),
               context(scope, message)
             )

    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "memory_policy_refused"
    refute Jason.encode!(refused) =~ fake_secret
    assert {:ok, []} = ProfileMemory.list_current(scope.owner)
  end

  test "remember is durable and idempotent for explicit statements", %{
    snapshot: snapshot
  } do
    scope = browser("memory-explicit")
    message = user_message(scope.conversation, "Remember that I prefer concise answers.")
    context = context(scope, message)

    request =
      call("memory_remember", %{
        "memories" => [
          %{"category" => "preference", "claim" => "I prefer concise answers"}
        ]
      })

    assert {:ok, first} = Runner.run(snapshot, request, context)
    assert first["status"] == "succeeded"
    assert first["result"]["receipt"]["disposition"] == "stored"
    assert [entry] = first["result"]["results"]
    assert entry["memory"]["claim"] == "I prefer concise answers"

    assert {:ok, repeated} = Runner.run(snapshot, %{request | call_id: "call-repeat"}, context)
    assert repeated["result"]["receipt"]["disposition"] == "already_active"

    plain = user_message(scope.conversation, "Remember that I like detailed answers.")

    assert {:ok, automatic} =
             Runner.run(
               snapshot,
               call("memory_remember", %{
                 "memories" => [
                   %{"category" => "preference", "claim" => "I like detailed answers"}
                 ]
               }),
               context(scope, plain)
             )

    assert automatic["status"] == "succeeded"
    assert automatic["result"]["receipt"]["disposition"] == "stored"
    assert {:ok, [_first, _second]} = ProfileMemory.list_current(scope.owner)
  end

  test "a single call with multiple unauthorized claims is refused", %{
    snapshot: snapshot
  } do
    scope = browser("memory-batch")
    message = user_message(scope.conversation, "I'm Chris, I run OpenAgents, and I like Elixir.")

    assert {:ok, refused} =
             Runner.run(
               snapshot,
               call("memory_remember", %{
                 "memories" => [
                   %{"category" => "name", "claim" => "Name is Chris"},
                   %{"category" => "role", "claim" => "Runs OpenAgents"},
                   %{"category" => "preference", "claim" => "Likes Elixir"}
                 ]
               }),
               context(scope, message)
             )

    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "memory_consent_required"
    assert {:ok, []} = ProfileMemory.list_current(scope.owner)
  end

  test "an unrecognized category is coerced to other when the claim is explicitly authorized", %{
    snapshot: snapshot
  } do
    scope = browser("memory-coerced-category")
    message = user_message(scope.conversation, "Remember that I use a split keyboard.")

    assert {:ok, stored} =
             Runner.run(
               snapshot,
               call("memory_remember", %{
                 "memories" => [
                   %{"category" => "Equipment", "claim" => "I use a split keyboard"}
                 ]
               }),
               context(scope, message)
             )

    assert stored["status"] == "succeeded"
    assert [entry] = stored["result"]["results"]
    assert entry["disposition"] == "stored"
    assert entry["category"] == "other"
    assert {:ok, [record]} = ProfileMemory.list_current(scope.owner)
    assert record.category == "other"
  end

  test "a paraphrased claim without exact current or host consent is refused", %{
    snapshot: snapshot
  } do
    scope = browser("memory-automatic")
    statement = user_message(scope.conversation, "I'm mostly working on the One repo lately.")

    assert {:ok, refused} =
             Runner.run(
               snapshot,
               call("memory_remember", %{
                 "memories" => [
                   %{"category" => "project", "claim" => "Mostly working on the One repo"}
                 ]
               }),
               context(scope, statement)
             )

    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "memory_consent_required"
    assert {:ok, []} = ProfileMemory.list_current(scope.owner)
  end

  test "a host-recorded confirmation covers its candidate and refuses a mismatch",
       %{
         snapshot: snapshot
       } do
    scope = browser("memory-confirmation")
    message = user_message(scope.conversation, "Yes, save that.")

    confirmed_context = %{
      context(scope, message)
      | memory_consent: %{
          "kind" => "exact_confirmation",
          "operation" => "remember",
          "claim" => "I prefer concise answers"
        }
    }

    assert_succeeded(
      Runner.run(
        snapshot,
        call("memory_remember", %{
          "memories" => [
            %{"category" => "preference", "claim" => "I prefer concise answers"}
          ]
        }),
        confirmed_context
      )
    )

    assert {:ok, refused} =
             Runner.run(
               snapshot,
               call("memory_remember", %{
                 "memories" => [
                   %{"category" => "preference", "claim" => "I prefer detailed answers"}
                 ]
               }),
               confirmed_context
             )

    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "memory_consent_mismatch"
    assert {:ok, records} = ProfileMemory.list_current(scope.owner)
    refute Enum.any?(records, &(&1.claim == "I prefer detailed answers"))
  end

  test "a fabricated claim with no consent record authorizing it is refused", %{
    snapshot: snapshot
  } do
    scope = browser("memory-fabricated")
    message = user_message(scope.conversation, "Discussing project plans.")

    assert {:ok, refused} =
             Runner.run(
               snapshot,
               call("memory_remember", %{
                 "memories" => [
                   %{"category" => "preference", "claim" => "I prefer detailed answers"}
                 ]
               }),
               context(scope, message)
             )

    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "memory_consent_required"
    assert {:ok, []} = ProfileMemory.list_current(scope.owner)
  end

  test "correct supersedes a conflicting record with the new claim", %{snapshot: snapshot} do
    scope = browser("memory-correct")
    original = remember(snapshot, scope, "name", "Name is Maya")
    message = user_message(scope.conversation, "Actually, I'm Riley now.")

    assert {:ok, corrected} =
             Runner.run(
               snapshot,
               call("memory_correct", %{
                 "record_id" => original.id,
                 "expected_generation" => original.generation,
                 "category" => "name",
                 "claim" => "Name is Riley"
               }),
               context(scope, message)
             )

    assert corrected["status"] == "succeeded"
    assert corrected["result"]["receipt"]["disposition"] == "corrected"

    assert String.starts_with?(
             corrected["result"]["superseded_record_ref"],
             "profile-memory:v1:#{original.id}:"
           )

    assert corrected["result"]["memory"]["claim"] == "Name is Riley"
    assert {:ok, [record]} = ProfileMemory.list_current(scope.owner)
    assert record.claim == "Name is Riley"
    assert record.supersedes_record_id == original.id
  end

  test "correct refuses a stale generation and a foreign record", %{snapshot: snapshot} do
    scope = browser("memory-correct-stale")
    original = remember(snapshot, scope, "role", "Role is data engineer")
    message = user_message(scope.conversation, "I'm a product designer now.")

    assert {:ok, stale} =
             Runner.run(
               snapshot,
               call("memory_correct", %{
                 "record_id" => original.id,
                 "expected_generation" => original.generation + 1,
                 "category" => "role",
                 "claim" => "Role is product designer"
               }),
               context(scope, message)
             )

    refute stale["status"] == "succeeded"

    foreign = browser("memory-correct-foreign")
    foreign_message = user_message(foreign.conversation, "I'm a product designer now.")

    assert {:ok, refused} =
             Runner.run(
               snapshot,
               call("memory_correct", %{
                 "record_id" => original.id,
                 "expected_generation" => original.generation,
                 "category" => "role",
                 "claim" => "Role is product designer"
               }),
               context(foreign, foreign_message)
             )

    refute refused["status"] == "succeeded"
    assert {:ok, [record]} = ProfileMemory.list_current(scope.owner)
    assert record.claim == "Role is data engineer"
    assert {:ok, []} = ProfileMemory.list_current(foreign.owner)
  end

  test "list and search read the frozen turn snapshot", %{snapshot: snapshot} do
    scope = browser("memory-frozen")
    remember_message = user_message(scope.conversation, "Remember that I prefer concise answers.")
    frozen_context = context(scope, remember_message)

    assert_succeeded(
      Runner.run(
        snapshot,
        call("memory_remember", %{
          "memories" => [
            %{"category" => "preference", "claim" => "I prefer concise answers"}
          ]
        }),
        frozen_context
      )
    )

    assert {:ok, frozen_list} =
             Runner.run(
               snapshot,
               call("memory_list", %{"category" => "", "first" => 10}),
               frozen_context
             )

    assert frozen_list["result"]["memories"] == []

    question = user_message(scope.conversation, "What do you remember about concise answers?")
    later_context = context(scope, question)

    assert {:ok, searched} =
             Runner.run(
               snapshot,
               call("memory_search", %{
                 "category" => "",
                 "first" => 10,
                 "query" => "concise"
               }),
               later_context
             )

    assert [memory] = searched["result"]["memories"]
    assert memory["claim"] == "I prefer concise answers"
    assert searched["result"]["snapshot_ref"] == later_context.profile_memory_snapshot_ref
  end

  test "record, category, and all-browser forget are explicit and idempotent", %{
    snapshot: snapshot
  } do
    scope = browser("memory-forget")
    preference = remember(snapshot, scope, "preference", "I prefer concise answers")
    _project = remember(snapshot, scope, "project", "My project is One")
    message = user_message(scope.conversation, "Forget that I prefer concise answers.")

    arguments = %{
      "mode" => "record",
      "record_id" => preference.id,
      "category" => "",
      "claim" => preference.claim,
      "expected_generation" => preference.generation
    }

    assert {:ok, forgotten} =
             Runner.run(snapshot, call("memory_forget", arguments), context(scope, message))

    assert forgotten["result"]["receipt"]["disposition"] == "forgotten"

    assert {:ok, repeated} =
             Runner.run(snapshot, call("memory_forget", arguments), context(scope, message))

    assert repeated["result"]["receipt"]["disposition"] == "already_absent"

    category_message = user_message(scope.conversation, "Forget all project memories.")

    assert_succeeded(
      Runner.run(
        snapshot,
        call("memory_forget", %{
          "mode" => "category",
          "record_id" => "",
          "category" => "project",
          "claim" => "",
          "expected_generation" => 0
        }),
        context(scope, category_message)
      )
    )

    all_message = user_message(scope.conversation, "Forget everything you remember about me.")

    assert_succeeded(
      Runner.run(
        snapshot,
        call("memory_forget", %{
          "mode" => "all",
          "record_id" => "",
          "category" => "",
          "claim" => "",
          "expected_generation" => 0
        }),
        context(scope, all_message)
      )
    )

    assert {:ok, []} = ProfileMemory.list_current(scope.owner)
  end

  test "a foreign record is indistinguishable from an absent record", %{snapshot: snapshot} do
    first = browser("memory-first-browser")
    second = browser("memory-second-browser")
    record = remember(snapshot, first, "other", "My marker is cedar")
    message = user_message(second.conversation, "Forget that My marker is cedar.")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("memory_forget", %{
                 "mode" => "record",
                 "record_id" => record.id,
                 "category" => "",
                 "claim" => record.claim,
                 "expected_generation" => record.generation
               }),
               context(second, message)
             )

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["receipt"]["disposition"] == "already_absent"
    assert {:ok, [_active]} = ProfileMemory.list_current(first.owner)
    assert {:ok, []} = ProfileMemory.list_current(second.owner)
  end

  defp browser(key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(key)
    %{owner: Repo.get!(Visitor, conversation.visitor_id), conversation: conversation}
  end

  defp user_message(conversation, content) do
    Repo.insert!(%Message{
      conversation_id: conversation.id,
      role: "user",
      status: "complete",
      content: content
    })
  end

  defp context(scope, message) do
    assert {:ok, profile_snapshot} = ProfileMemory.capture_snapshot(scope.owner)

    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{scope.conversation.id}",
      authorities: MapSet.new(["memory.read", "memory.write"]),
      conversation_id: scope.conversation.id,
      current_user_message_id: message.id,
      owner_visitor_id: scope.owner.id,
      profile_memory_snapshot_ref: profile_snapshot.ref
    }
  end

  defp remember(snapshot, scope, category, claim) do
    message = user_message(scope.conversation, "Remember that #{claim}.")

    assert {:ok, outcome} =
             Runner.run(
               snapshot,
               call("memory_remember", %{
                 "memories" => [%{"category" => category, "claim" => claim}]
               }),
               context(scope, message)
             )

    assert outcome["status"] == "succeeded"
    assert {:ok, records} = ProfileMemory.list_current(scope.owner)
    Enum.find(records, &(&1.category == category and &1.claim == claim))
  end

  defp call(name, arguments) do
    %{
      call_id: "call-#{System.unique_integer([:positive])}",
      name: name,
      version: 1,
      raw_arguments: Jason.encode!(arguments)
    }
  end

  defp assert_succeeded({:ok, outcome}), do: assert(outcome["status"] == "succeeded")
end
