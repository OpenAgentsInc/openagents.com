defmodule OpenAgents.InferenceTest do
  use OpenAgents.DataCase, async: false
  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Inference
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Inference.{Models, Pricing}
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.UnpricedLane

  defp scope(key) do
    owner = github_user("inf-#{key}")
    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "inf-box-#{key}",
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/home/x/code"]
      })

    {:ok, machine} = Machines.approve_pairing(owner, code)

    %{
      owner_visitor_id: conversation.visitor_id,
      conversation_id: conversation.id,
      machine_id: machine.id
    }
  end

  describe "mint/1" do
    test "mints an active grant, returns the plaintext once, stores only a digest" do
      input = scope("mint")
      {:ok, grant, token} = Inference.mint(input)

      assert grant.status == "active"
      assert grant.model_id == OpenAgents.Inference.Models.default_id()
      assert String.starts_with?(token, "sig_")
      assert grant.max_calls > 0
      # Only the digest is stored; the token is not recoverable from the row.
      refute grant.token_digest == token
      assert grant.token_digest == :crypto.hash(:sha256, token)
    end

    test "pins a named model, publishing the public id rather than the vendor one" do
      {:ok, grant, _token} =
        Inference.mint(Map.put(scope("mint-named"), :model_id, "glm-5.3-flash"))

      assert grant.model_id == "glm-5.3-flash"
    end

    test "refuses a model the proxy cannot route, naming only the model" do
      input = Map.put(scope("mint-unrouted"), :model_id, "attacker/gpt-9-ultra")

      assert {:error, changeset} = Inference.mint(input)
      assert [model_id: {sentence, _opts}] = changeset.errors
      assert sentence =~ "is not a model this proxy routes"
    end
  end

  describe "resolve/1" do
    test "resolves an active, in-budget grant" do
      {:ok, _grant, token} = Inference.mint(scope("resolve-ok"))
      assert {:ok, %Grant{status: "active"}} = Inference.resolve(token)
    end

    test "fails closed for unknown, revoked, expired, and exhausted grants" do
      assert {:error, :grant_not_found} = Inference.resolve("sig_nope")

      {:ok, grant, token} = Inference.mint(scope("resolve-revoked"))
      {:ok, _} = Inference.revoke(grant)
      assert {:error, :grant_revoked} = Inference.resolve(token)

      # Mint already-expired via a negative TTL (expires_at is immutable once
      # written, per the trigger — the correct way to test expiry is at mint).
      previous = Application.fetch_env!(:openagents, :inference_grant_ttl_seconds)
      Application.put_env(:openagents, :inference_grant_ttl_seconds, -60)
      {:ok, expired, expired_token} = Inference.mint(scope("resolve-expired"))
      Application.put_env(:openagents, :inference_grant_ttl_seconds, previous)

      assert {:error, :grant_expired} = Inference.resolve(expired_token)
      # And it was transitioned to a terminal state, not left active.
      assert Repo.get(Grant, expired.id).status == "expired"
    end

    test "refuses an over-budget grant" do
      {:ok, grant, token} = Inference.mint(scope("resolve-budget"))
      # Meter enough to reach the token ceiling.
      {:ok, _} =
        Inference.record_usage(grant, %{
          "input_tokens" => grant.max_total_tokens,
          "output_tokens" => 0
        })

      assert {:error, :grant_exhausted} = Inference.resolve(token)
    end
  end

  describe "record_usage/2" do
    test "merges usage, prices cost, increments the call count" do
      {:ok, grant, _token} = Inference.mint(scope("usage"))
      {:ok, once} = Inference.record_usage(grant, %{"input_tokens" => 100, "output_tokens" => 40})

      assert once.call_count == 1
      assert once.usage["input_tokens"] == 100
      assert once.usage["output_tokens"] == 40
      assert once.usage["total_tokens"] == 140
      assert once.usage["estimated_cost_microusd"] >= 0
      assert once.usage["pricing_id"] == Pricing.pricing_id_for(grant.model_id)
      assert once.usage["schema"] == "sarah.inference_grant_usage.v1"

      {:ok, twice} = Inference.record_usage(once, %{"input_tokens" => 10, "output_tokens" => 5})
      assert twice.call_count == 2
      assert twice.usage["input_tokens"] == 110
      assert twice.usage["total_tokens"] == 155
    end

    test "records cache read input tokens when the provider reports them" do
      {:ok, grant, _token} = Inference.mint(scope("usage-cache"))

      {:ok, once} =
        Inference.record_usage(grant, %{
          "input_tokens" => 100,
          "output_tokens" => 40,
          "cache_read_input_tokens" => 20
        })

      assert once.usage["input_tokens"] == 100
      assert once.usage["output_tokens"] == 40
      assert once.usage["cache_read_input_tokens"] == 20
      assert once.usage["total_tokens"] == 140

      {:ok, twice} =
        Inference.record_usage(once, %{
          "input_tokens" => 10,
          "output_tokens" => 5,
          "cache_read_input_tokens" => 3
        })

      assert twice.usage["cache_read_input_tokens"] == 23
    end

    test "omits cache splits when the provider does not report them" do
      {:ok, grant, _token} = Inference.mint(scope("usage-no-cache"))

      {:ok, once} =
        Inference.record_usage(grant, %{"input_tokens" => 100, "output_tokens" => 40})

      refute Map.has_key?(once.usage, "cache_read_input_tokens")
      refute Map.has_key?(once.usage, "cache_write_input_tokens")
      assert once.usage["input_tokens"] == 100
      assert once.usage["total_tokens"] == 140
    end

    test "preserves existing cache read tokens when a later call reports none" do
      {:ok, grant, _token} = Inference.mint(scope("usage-cache-persist"))

      {:ok, once} =
        Inference.record_usage(grant, %{
          "input_tokens" => 100,
          "output_tokens" => 40,
          "cache_read_input_tokens" => 20
        })

      {:ok, twice} =
        Inference.record_usage(once, %{"input_tokens" => 10, "output_tokens" => 5})

      assert twice.usage["cache_read_input_tokens"] == 20
      refute Map.has_key?(twice.usage, "cache_write_input_tokens")
    end

    test "flips the grant to exhausted when a ceiling is reached" do
      {:ok, grant, _token} = Inference.mint(scope("usage-exhaust"))

      {:ok, exhausted} =
        Inference.record_usage(grant, %{
          "input_tokens" => grant.max_total_tokens + 1,
          "output_tokens" => 0
        })

      assert exhausted.status == "exhausted"
      assert exhausted.exhausted_at != nil
    end

    test "refuses to meter a terminal grant" do
      {:ok, grant, _token} = Inference.mint(scope("usage-terminal"))
      {:ok, revoked} = Inference.revoke(grant)
      assert {:error, :grant_not_active} = Inference.record_usage(revoked, %{"input_tokens" => 1})
    end

    test "prices cost from the model's declared rates, with cached reads at the cached rate" do
      {:ok, grant, _token} = Inference.mint(scope("usage-priced"))

      input = 100
      output = 40
      cache_read = 20

      {:ok, metered} =
        Inference.record_usage(grant, %{
          "input_tokens" => input,
          "output_tokens" => output,
          "cache_read_input_tokens" => cache_read
        })

      pricing = Pricing.effective_pricing(Models.default())

      expected =
        ((input - cache_read) * pricing.input_per_million_tokens +
           cache_read * pricing.cached_input_per_million_tokens +
           output * pricing.output_per_million_tokens)
        |> div(1_000_000)

      assert metered.usage["estimated_cost_microusd"] == expected
      # The record names the table it was priced against, so the figure can be
      # dereferenced rather than trusted (METER-001).
      assert metered.usage["pricing_id"] == pricing.id
    end

    test "an unpriced model records no estimated cost — and no zero" do
      # `gpt-5.6-luna` was the shipped unpriced lane until it was withdrawn.
      # The behaviour it demonstrated is unchanged, so the lane is admitted
      # here for the length of this test rather than shipped for everyone.
      previous = UnpricedLane.admit!()
      on_exit(fn -> UnpricedLane.restore(previous) end)

      {:ok, grant, _token} =
        Inference.mint(Map.put(scope("usage-unpriced"), :model_id, UnpricedLane.id()))

      {:ok, metered} =
        Inference.record_usage(grant, %{
          "input_tokens" => 100,
          "output_tokens" => 40
        })

      refute Map.has_key?(metered.usage, "estimated_cost_microusd")
      refute metered.usage["estimated_cost_microusd"] == 0
      # The record says why there is no cost rather than leaving a reader to
      # infer it from a missing key.
      assert metered.usage["pricing_id"] == "unpriced"
      # Tokens are still measured. Unpriced is not unmetered: the call is
      # evidenced, only its price is unknown.
      assert metered.usage["total_tokens"] == 140
    end
  end

  describe "fences" do
    test "mint/1 accepts a thread fence and names no conversation" do
      owner = github_user("inf-thread")
      {:ok, thread} = OpenAgents.Threads.open(owner, "Reach a model from a thread")

      {:ok, grant, token} =
        Inference.mint(%{
          owner_visitor_id: thread.owner_visitor_id,
          thread_id: thread.id,
          machine_id: nil
        })

      assert grant.thread_id == thread.id
      assert grant.conversation_id == nil
      assert {:ok, %Grant{status: "active"}} = Inference.resolve(token)
    end

    test "mint/1 refuses a grant naming both fences or neither" do
      input = scope("inf-both")

      assert {:error, changeset} =
               Inference.mint(Map.put(input, :thread_id, Ecto.UUID.generate()))

      assert %{thread_id: _} = errors_on(changeset)

      assert {:error, changeset} = Inference.mint(Map.delete(input, :conversation_id))
      assert %{thread_id: _} = errors_on(changeset)
    end

    test "revoke_active_for_thread revokes every active grant for one thread" do
      owner = github_user("inf-thread-fence")
      {:ok, thread} = OpenAgents.Threads.open(owner, "Fence a thread")

      {:ok, _grant, token} =
        Inference.mint(%{
          owner_visitor_id: thread.owner_visitor_id,
          thread_id: thread.id,
          machine_id: nil
        })

      assert {1, nil} = Inference.revoke_active_for_thread(thread.id)
      assert {:error, :grant_revoked} = Inference.resolve(token)
      assert {0, nil} = Inference.revoke_active_for_thread(nil)
    end
  end

  describe "generation fence" do
    test "revoke_active_for_conversation revokes every active grant for one conversation" do
      scope = scope("fence")
      {:ok, _g1, t1} = Inference.mint(scope)
      {:ok, _g2, t2} = Inference.mint(scope)

      {count, _} = Inference.revoke_active_for_conversation(scope.conversation_id)
      assert count == 2
      assert {:error, :grant_revoked} = Inference.resolve(t1)
      assert {:error, :grant_revoked} = Inference.resolve(t2)
    end
  end

  describe "immutability" do
    test "a terminal grant cannot be updated (database trigger)" do
      {:ok, grant, _token} = Inference.mint(scope("immutable"))
      {:ok, revoked} = Inference.revoke(grant)

      assert_raise Postgrex.Error, ~r/terminal/, fn ->
        revoked
        |> Ecto.Changeset.change(call_count: 99)
        |> Repo.update()
      end
    end
  end
end
