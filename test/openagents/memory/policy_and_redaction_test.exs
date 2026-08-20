defmodule OpenAgents.Memory.PolicyAndRedactionTest do
  use OpenAgents.SarahDataCase

  import ExUnit.CaptureLog

  alias OpenAgents.{Context.Composer, Conversations, ProfileMemory, Repo}
  alias OpenAgents.Conversations.{Message, Visitor}
  alias OpenAgents.Memory.{Policy, PolicyEvent, Redaction}
  alias OpenAgents.ProfileMemory.Record

  @secret_cases [
    {:credential_material, "password = hunter2!"},
    {:credential_material, "-----BEGIN PRIVATE KEY----- ABCDEF"},
    {:api_token, "api_key: abcdef1234567890"},
    {:api_token, "sk-" <> "proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"},
    {:api_token, "gh" <> "p_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"},
    {:api_token, "AK" <> "IAABCDEFGHIJKLMNOP"},
    {:api_token, "xox" <> "b-1234567890-abcdefghijklmnop"},
    {:wallet_seed_material, "seed phrase: alpha beta gamma delta epsilon zeta"},
    {:wallet_seed_material, "wallet private key = 0x" <> String.duplicate("a", 64)},
    {:payment_material, "card number: 4242 4242 4242 4242"},
    {:payment_material, "my visa is 4111 1111 1111 1111 thanks"},
    {:payment_material, "cvv=123"},
    {:authentication_secret, "Authorization: Bearer abcdefghijklmnopqrstuvwxyz"},
    {:authentication_secret, "refresh_token=refresh-abcdef123456"},
    {:authentication_secret, "session_cookie=session-private-abcdef123456"},
    {:local_path, "My file is /Users/private/work/secret.txt"},
    {:local_path, "Use C:\\Users\\private\\secret.txt"}
  ]

  # A Luhn-passing digit run embedded in a longer alphanumeric token — a
  # sha256 provenance ref, a UUID fragment, a commit hash — is not a card.
  # Before the token-boundary fix, portable imports failed by hash lottery
  # whenever an installation ref happened to contain such a run.
  test "digit runs inside hex tokens are not payment material" do
    embedded = "provenance ref 0d9e4111111111111111f7a2c3b8e6d1a0f4b7c2d5e8f1a4b7c0d3e6f9a2b5c8"
    assert :safe = Redaction.classify(embedded)
    assert :safe = Redaction.classify("origin 4111111111111111abc")
    assert {:reject, :payment_material} = Redaction.classify("4111111111111111")
  end

  test "supported secret classes are rejected deterministically" do
    for {reason, claim} <- @secret_cases do
      assert {:reject, ^reason} = Redaction.classify(claim), claim
      assert {:withheld, reason_code} = Redaction.project(claim)
      assert reason_code == Atom.to_string(reason)
      refute inspect(Redaction.project(claim)) =~ claim
    end
  end

  test "normalization and encoding tricks cannot bypass the gate" do
    split_token = "s​k - proj - ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"
    base64 = Base.encode64("password=hunter2!")
    hex = Base.encode16("api_key=abcdef1234567890", case: :lower)

    assert {:reject, :api_token} = Redaction.classify(split_token)
    assert {:reject, :encoded_secret_material} = Redaction.classify("encoded: #{base64}")
    assert {:reject, :encoded_secret_material} = Redaction.classify("hex: #{hex}")
    assert {:reject, :encoded_secret_material} = Redaction.classify(<<255, 254, 253>>)
  end

  test "already-redacted values and conservative false-positive fixtures remain safe" do
    safe = [
      "API key: [REDACTED]",
      "password = ********",
      "My role is API platform engineer.",
      "I use API keys during development.",
      "My favorite number is 4242.",
      "The conceptual path to launch is documentation first.",
      "The endpoint path is /v1/responses.",
      "I use 1Password as a product.",
      "The checksum is #{String.duplicate("a", 64)}."
    ]

    for claim <- safe do
      assert :safe = Redaction.classify(claim), claim
      assert {:ok, ^claim} = Redaction.project(claim)
    end
  end

  test "rejection persists only bounded versioned metadata and leaks nowhere downstream" do
    {owner, _conversation} = owner("memory-policy-rejection-browser")
    secret = "sk-" <> "proj-UNIQUEPRIVATEVALUE12345678901234567890"

    result =
      capture_log(fn ->
        assert {:error, {:memory_policy_rejected, "api_token"}} =
                 ProfileMemory.create_candidate(owner, attributes(secret))
      end)

    refute result =~ secret
    refute inspect({:error, {:memory_policy_rejected, "api_token"}}) =~ secret
    refute Repo.exists?(from(record in Record, where: record.owner_visitor_id == ^owner.id))

    assert {:ok, [event]} = Policy.list_rejections(owner)

    assert event == %{
             "id" => event["id"],
             "policy_version" => Policy.version(),
             "outcome" => "rejected",
             "reason_code" => "api_token",
             "category" => "preference",
             "input_size_bucket" => "1-64",
             "recorded_at" => event["recorded_at"]
           }

    refute inspect(event) =~ secret

    stored_event =
      Repo.one!(from(policy_event in PolicyEvent, where: policy_event.id == ^event["id"]))

    refute inspect(stored_event) =~ secret

    assert {:ok, export} = ProfileMemory.export(owner)
    refute inspect(export) =~ secret
    refute Composer.compose!().instructions =~ secret
  end

  test "rejection audits and policy receipts are browser scoped" do
    {first, _conversation} = owner("memory-policy-first-browser")
    {second, _conversation} = owner("memory-policy-second-browser")
    secret = "refresh_token=first-browser-private-123456"

    assert {:error, {:memory_policy_rejected, "authentication_secret"}} =
             ProfileMemory.create_candidate(first, attributes(secret))

    assert {:ok, [_event]} = Policy.list_rejections(first)
    assert {:ok, []} = Policy.list_rejections(second)
    assert {:error, :invalid_limit} = Policy.list_rejections(first, limit: 101)
  end

  test "safe records pin policy identities and export revalidates projection" do
    {owner, _conversation} = owner("memory-policy-safe-browser")
    claim = "I prefer short project updates."
    assert {:ok, candidate} = ProfileMemory.create_candidate(owner, attributes(claim))
    assert candidate.policy_version == "sarah.memory.policy.v1"
    assert candidate.redaction_policy == "sarah.memory.redaction.v1"

    assert {:ok, export} = ProfileMemory.export(owner)
    assert [projected] = export["records"]
    assert projected["claim"] == claim
    assert projected["projection"] == "admitted"
    assert projected["withheld_reason"] == nil
    assert projected["policy_version"] == Policy.version()
    assert projected["redaction_policy"] == Redaction.version()
  end

  test "unsafe provenance and source content cannot bypass a safe-looking claim" do
    {owner, conversation} = owner("memory-policy-nested-content-browser")
    provenance_secret = "gh" <> "p_NESTEDPRIVATEVALUE123456789012345"
    source_secret = "password=source-private-value"

    assert {:error, {:memory_policy_rejected, "api_token"}} =
             ProfileMemory.create_candidate(owner, %{
               attributes("A safe-looking preference.")
               | provenance: %{"note" => provenance_secret}
             })

    source =
      Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: "user",
        status: "complete",
        content: source_secret
      })

    assert {:error, {:memory_policy_rejected, "credential_material"}} =
             ProfileMemory.create_candidate(owner, %{
               attributes("Another safe-looking preference.")
               | sources: [%{source_ref: "message:#{source.id}", kind: "owner_statement"}],
                 owner_asserted: false
             })

    refute Repo.exists?(from(record in Record, where: record.owner_visitor_id == ^owner.id))
    assert {:ok, events} = Policy.list_rejections(owner)

    assert Enum.sort(Enum.map(events, & &1["reason_code"])) == [
             "api_token",
             "credential_material"
           ]

    refute inspect(events) =~ provenance_secret
    refute inspect(events) =~ source_secret
  end

  test "projection revalidation withholds a source that becomes unsafe after admission" do
    {owner, conversation} = owner("memory-policy-projection-recheck-browser")

    source =
      Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: "user",
        status: "complete",
        content: "Remember that I prefer short updates."
      })

    attributes = %{
      attributes("I prefer short updates.")
      | sources: [%{source_ref: "message:#{source.id}", kind: "owner_statement"}],
        owner_asserted: false
    }

    assert {:ok, candidate} = ProfileMemory.create_candidate(owner, attributes)

    assert {:ok, _active} =
             ProfileMemory.transition(owner, candidate.id, candidate.generation, "active")

    changed_secret = "password=changed-after-admission-private-value"
    source |> Message.changeset(%{content: changed_secret}) |> Repo.update!()

    assert {:ok, snapshot} = ProfileMemory.capture_snapshot(owner)
    assert {:ok, [projection]} = ProfileMemory.project_active(owner, snapshot)
    assert [%{"source_ref" => nil, "projection" => "withheld"}] = projection["sources"]
    refute inspect(projection) =~ changed_secret

    assert {:ok, export} = ProfileMemory.export(owner)
    refute inspect(export) =~ changed_secret
    refute inspect(export) =~ source.id
  end

  defp owner(browser_key) do
    {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    {Repo.get!(Visitor, conversation.visitor_id), conversation}
  end

  defp attributes(claim) do
    %{
      category: "preference",
      claim: claim,
      creator: "user_explicit",
      provenance: %{"intent" => "remember"},
      owner_asserted: true,
      sources: []
    }
  end
end
