defmodule OpenAgents.Memories.ChallengeTest do
  @moduledoc """
  Disagreement about a system memory: who may record it, what it does to the
  derived status, and what it still may not reach.

  Five properties carry the weight here.

  **A challenge is a record, not an edit.** A reader who finds an admitted
  claim wrong writes a row stating the ground. Nothing updates the claim, and a
  reversal is a further record — so these tests read the whole history back and
  check that every step of an argument survives it.

  **Evidence is the distinction recall turns on.** An evidenced challenge
  suspends its target; an unevidenced one is recorded and changes nothing. An
  empty evidence list is neither: the table refuses it, so these tests insert
  around the changeset to prove the refusal is the store's rather than the
  write path's.

  **Only a steward resolves.** A refutation from an ordinary account is
  refused, and the refusal changes nothing and reveals nothing.

  **The derivation is order-independent.** The same set of records derives the
  same statuses however they arrive, including a refutation dated earlier than
  the challenge it resolves. Every permutation is checked, not asserted.

  **And the bucket still surfaces to nobody.** MEMORY-001 and MEMORY-010 hold
  unchanged: a suspended memory, a challenged one, and an admitted one all
  reach the same number of turns, which is none.
  """
  use OpenAgents.DataCase, async: true

  alias OpenAgents.Memories
  alias OpenAgents.Memories.{Admission, Admissions, Memory, Recall}

  # The owner account is an operator by definition (`@owner_github_id`), so a
  # steward needs no configuration change and these tests stay async.
  @owner_github_id 14_167_547

  @ground "The receipt this cites was superseded before the claim was written."

  defp account(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()

    upsert(github_id, "chl-" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 12)))
  end

  defp steward, do: upsert(@owner_github_id, "AtlantisPleb")

  defp upsert(github_id, login) do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  defp evidence(ref \\ "receipt:4f1c") do
    [%{"kind" => "receipt", "ref" => ref, "digest" => "sha256:9ab3"}]
  end

  defp candidate(overrides) do
    Map.merge(
      %{
        "bucket" => "system",
        "slug" => "sys:gateway-402-retired-model",
        "body" => "A 402 from the gateway means the default model was retired upstream.",
        "tier" => "ledger",
        "as_of" => ~D[2026-08-25],
        "admission" => "candidate",
        "evidence_refs" => evidence()
      },
      overrides
    )
  end

  # An admitted system memory, which is the only thing a challenge can suspend.
  defp admitted(author, slug) do
    {:ok, memory} = Memories.create(author, candidate(%{"slug" => slug}))

    {:ok, _verdict} =
      Admissions.record(steward(), memory.id, %{
        "verdict" => "admitted",
        "ground" => "The receipt shows the 402 and the retirement together."
      })

    memory
  end

  # A record assembled as a struct rather than through a changeset. This is the
  # second write path the constraints exist for, and the one that proves the
  # refusal belongs to the table.
  defp around_the_changeset(fields) do
    Repo.insert(struct(Admission, Map.merge(%{memory_bucket: "system"}, fields)))
  end

  describe "writing a challenge" do
    test "any account records one against an admitted claim" do
      author = account("write-author")
      reader = account("write-reader")

      memory = admitted(author, "sys:write-any-account")

      assert {:ok, challenge} =
               Admissions.challenge(reader, memory.id, %{
                 "ground" => @ground,
                 "evidence_refs" => evidence("receipt:0a11")
               })

      assert challenge.role == "challenge"
      assert challenge.slug == "chl:" <> memory.id
      assert challenge.author_id == reader.id
      assert challenge.memory_id == memory.id
      assert challenge.verdict == nil
      assert challenge.ground == @ground
      assert challenge.inserted_at != nil
      assert Admission.evidenced_challenge?(challenge)
    end

    test "the claim's own author may challenge it too" do
      author = account("write-self")
      memory = admitted(author, "sys:write-self")

      assert {:ok, challenge} =
               Admissions.challenge(author, memory.id, %{"ground" => @ground})

      assert challenge.author_id == author.id
      refute Admission.evidenced_challenge?(challenge)
    end

    test "a challenge needs a ground" do
      author = account("write-ground")
      memory = admitted(author, "sys:write-ground")

      assert {:error, changeset} = Admissions.challenge(author, memory.id, %{})
      assert %{ground: _refused} = errors_on(changeset)
    end

    test "an empty evidence list is refused rather than read as unevidenced" do
      author = account("write-empty-evidence")
      memory = admitted(author, "sys:write-empty-evidence")

      assert {:error, changeset} =
               Admissions.challenge(author, memory.id, %{
                 "ground" => @ground,
                 "evidence_refs" => []
               })

      assert %{evidence_refs: _refused} = errors_on(changeset)
    end

    test "an evidence ref with no digest is refused" do
      author = account("write-bad-evidence")
      memory = admitted(author, "sys:write-bad-evidence")

      assert {:error, changeset} =
               Admissions.challenge(author, memory.id, %{
                 "ground" => @ground,
                 "evidence_refs" => [%{"kind" => "url", "ref" => "https://openagents.com/"}]
               })

      assert %{evidence_refs: _refused} = errors_on(changeset)
    end

    # The composite foreign key, not a read. A memory outside the system bucket
    # is not challengeable, and saying so costs no query across an account.
    test "a challenge naming a memory outside the system bucket is refused" do
      author = account("write-wrong-bucket")

      {:ok, plain} = Memories.create(author, %{"body" => "I use pnpm."})

      assert {:error, :not_found} =
               Admissions.challenge(author, plain.id, %{"ground" => @ground})

      assert {:error, :not_found} =
               Admissions.challenge(author, Ecto.UUID.generate(), %{"ground" => @ground})

      assert {:error, :not_found} =
               Admissions.challenge(author, "not-a-uuid", %{"ground" => @ground})

      assert Repo.aggregate(Admission, :count) == 0
    end
  end

  describe "writing a refutation" do
    test "a steward resolves one challenge" do
      author = account("refute-author")
      reader = account("refute-reader")
      resolving = steward()

      memory = admitted(author, "sys:refute-steward")

      {:ok, challenge} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      assert {:ok, refutation} =
               Admissions.refute(resolving, challenge.id, %{
                 "ground" => "The receipt it cites is current; the supersession named another."
               })

      assert refutation.role == "refutation"
      assert refutation.slug == "ref:" <> challenge.id
      assert refutation.challenge_id == challenge.id
      assert refutation.memory_id == memory.id
      assert refutation.author_id == resolving.id
      assert refutation.verdict == nil
    end

    test "an ordinary account is refused, and the refusal changes nothing" do
      author = account("refute-non-steward")
      reader = account("refute-non-steward-reader")

      memory = admitted(author, "sys:refute-non-steward")

      {:ok, challenge} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      for account <- [author, reader] do
        assert {:error, :steward_required} =
                 Admissions.refute(account, challenge.id, %{"ground" => "I disagree."})
      end

      assert Admissions.status(memory) == "suspended"
      assert Enum.count(Admissions.list(memory), &(&1.role == "refutation")) == 0
    end

    # The role check runs before the challenge is read, so a caller with no
    # standing cannot tell a real challenge id from an invented one.
    test "an account without the role learns nothing about the challenge it named" do
      stranger = account("refute-stranger")

      assert {:error, :steward_required} =
               Admissions.refute(stranger, Ecto.UUID.generate(), %{"ground" => "No."})

      assert {:error, :steward_required} =
               Admissions.refute(stranger, "not-a-uuid", %{"ground" => "No."})
    end

    test "a refutation of something that is not a challenge is refused" do
      author = account("refute-not-a-challenge")
      resolving = steward()

      memory = admitted(author, "sys:refute-not-a-challenge")
      [verdict] = Admissions.list(memory)

      assert {:error, :not_found} =
               Admissions.refute(resolving, verdict.id, %{"ground" => "Not a challenge."})

      assert {:error, :not_found} =
               Admissions.refute(resolving, Ecto.UUID.generate(), %{"ground" => "Nothing."})

      assert {:error, :not_found} =
               Admissions.refute(resolving, "not-a-uuid", %{"ground" => "Nothing."})
    end

    test "a refutation needs a ground" do
      author = account("refute-ground")
      resolving = steward()

      memory = admitted(author, "sys:refute-ground")

      {:ok, challenge} =
        Admissions.challenge(author, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      assert {:error, changeset} = Admissions.refute(resolving, challenge.id, %{})
      assert %{ground: _refused} = errors_on(changeset)
    end
  end

  describe "derived status" do
    test "an evidenced challenge suspends an admitted claim" do
      author = account("status-suspends")
      reader = account("status-suspends-reader")

      memory = admitted(author, "sys:status-suspends")
      assert Admissions.status(memory) == "admitted"

      {:ok, _challenge} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      assert Admissions.status(memory) == "suspended"
    end

    test "an unevidenced challenge is recorded and changes nothing" do
      author = account("status-unevidenced")
      reader = account("status-unevidenced-reader")

      memory = admitted(author, "sys:status-unevidenced")

      {:ok, challenge} = Admissions.challenge(reader, memory.id, %{"ground" => @ground})

      assert Admissions.status(memory) == "admitted"
      assert challenge.id in Enum.map(Admissions.list(memory), & &1.id)
    end

    test "a challenge against a candidate or a rejected claim changes nothing" do
      author = account("status-not-admitted")
      reader = account("status-not-admitted-reader")

      {:ok, proposed} = Memories.create(author, candidate(%{"slug" => "sys:status-candidate"}))

      {:ok, refused} = Memories.create(author, candidate(%{"slug" => "sys:status-rejected"}))

      {:ok, _verdict} =
        Admissions.record(steward(), refused.id, %{
          "verdict" => "rejected",
          "ground" => "The digest does not match the receipt it names."
        })

      for memory <- [proposed, refused] do
        {:ok, _challenge} =
          Admissions.challenge(reader, memory.id, %{
            "ground" => @ground,
            "evidence_refs" => evidence("receipt:0a11")
          })
      end

      assert Admissions.status(proposed) == "candidate"
      assert Admissions.status(refused) == "rejected"
    end

    test "a refutation restores the claim" do
      author = account("status-refuted")
      reader = account("status-refuted-reader")
      resolving = steward()

      memory = admitted(author, "sys:status-refuted")

      {:ok, challenge} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      assert Admissions.status(memory) == "suspended"

      {:ok, _refutation} =
        Admissions.refute(resolving, challenge.id, %{"ground" => "The receipt is current."})

      assert Admissions.status(memory) == "admitted"
    end

    test "a refutation resolves the one challenge it names and no other" do
      author = account("status-two-challenges")
      first = account("status-two-challenges-first")
      second = account("status-two-challenges-second")
      resolving = steward()

      memory = admitted(author, "sys:status-two-challenges")

      {:ok, one} =
        Admissions.challenge(first, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      {:ok, two} =
        Admissions.challenge(second, memory.id, %{
          "ground" => "The claim reverses cause and effect.",
          "evidence_refs" => evidence("receipt:0b22")
        })

      {:ok, _refutation} =
        Admissions.refute(resolving, one.id, %{"ground" => "The first ground does not stand."})

      assert Admissions.status(memory) == "suspended"

      {:ok, _refutation} =
        Admissions.refute(resolving, two.id, %{"ground" => "Nor does the second."})

      assert Admissions.status(memory) == "admitted"
    end

    test "a second refutation of the same challenge changes nothing" do
      author = account("status-double-refutation")
      resolving = steward()

      memory = admitted(author, "sys:status-double-refutation")

      {:ok, challenge} =
        Admissions.challenge(author, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      {:ok, _first} = Admissions.refute(resolving, challenge.id, %{"ground" => "It stands."})
      assert Admissions.status(memory) == "admitted"

      {:ok, _second} = Admissions.refute(resolving, challenge.id, %{"ground" => "Still stands."})
      assert Admissions.status(memory) == "admitted"
    end

    # A reversal is a further record, never an edit of one that exists.
    test "a new challenge after a refutation suspends the claim again" do
      author = account("status-reversal")
      reader = account("status-reversal-reader")
      resolving = steward()

      memory = admitted(author, "sys:status-reversal")

      {:ok, first} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      {:ok, _refutation} =
        Admissions.refute(resolving, first.id, %{"ground" => "The receipt is current."})

      assert Admissions.status(memory) == "admitted"

      {:ok, _second} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => "The receipt is current and still does not say this.",
          "evidence_refs" => evidence("receipt:0c33")
        })

      assert Admissions.status(memory) == "suspended"

      # And the argument reads back whole: nothing was overwritten.
      assert Enum.map(Admissions.list(memory), & &1.role) ==
               ["admission", "challenge", "refutation", "challenge"]
    end

    test "re-admitting a suspended claim does not resolve the challenge" do
      author = account("status-readmit")
      reader = account("status-readmit-reader")
      admitting = steward()

      memory = admitted(author, "sys:status-readmit")

      {:ok, _challenge} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      {:ok, _verdict} =
        Admissions.record(admitting, memory.id, %{
          "verdict" => "admitted",
          "ground" => "Re-read the receipt and it still holds."
        })

      assert Admissions.status(memory) == "suspended"
    end

    test "a memory outside the system bucket has no status, and an unknown id none either" do
      author = account("status-other-bucket")

      {:ok, plain} = Memories.create(author, %{"body" => "I use pnpm."})

      assert Admissions.status(plain) == nil
      assert Admissions.status("not-a-uuid") == nil
      assert Admissions.status(Ecto.UUID.generate()) == "candidate"
    end
  end

  describe "supersession as the other resolution path" do
    test "a steward's correction resolves every open challenge on the target" do
      author = account("supersede-resolves")
      reader = account("supersede-resolves-reader")
      correcting = steward()

      memory = admitted(author, "sys:supersede-resolves")

      {:ok, challenge} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      assert Admissions.status(memory) == "suspended"

      assert {:ok, replacement} =
               Admissions.supersede(
                 correcting,
                 memory.id,
                 candidate(%{
                   "slug" => "sys:supersede-resolves",
                   "body" => "The gateway 402s when the default model is retired."
                 })
               )

      assert Repo.get!(Memory, memory.id).superseded_by_id == replacement.id
      assert Admissions.status(memory) == "admitted"

      # The resolution is a receipt, attributed and dated, not something a
      # reader has to infer from the pointer.
      assert [resolution] = Enum.filter(Admissions.list(memory), &(&1.role == "refutation"))
      assert resolution.challenge_id == challenge.id
      assert resolution.author_id == correcting.id
    end

    test "an author's correction resolves nothing" do
      author = account("supersede-author-resolves")
      reader = account("supersede-author-resolves-reader")

      memory = admitted(author, "sys:supersede-author-resolves")

      {:ok, _challenge} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      assert {:ok, _replacement} =
               Admissions.supersede(
                 author,
                 memory.id,
                 candidate(%{"slug" => "sys:supersede-author-resolves", "body" => "Corrected."})
               )

      assert Admissions.status(memory) == "suspended"
      assert Enum.count(Admissions.list(memory), &(&1.role == "refutation")) == 0
    end

    test "a correction with nothing challenged writes no resolution" do
      author = account("supersede-no-challenges")
      correcting = steward()

      memory = admitted(author, "sys:supersede-no-challenges")

      assert {:ok, _replacement} =
               Admissions.supersede(
                 correcting,
                 memory.id,
                 candidate(%{"slug" => "sys:supersede-no-challenges", "body" => "Corrected."})
               )

      assert Enum.count(Admissions.list(memory), &(&1.role == "refutation")) == 0
    end
  end

  describe "the challenge-flood cap" do
    test "the cap is a quarter of the admitted store, rounded up" do
      assert Admissions.challenge_share() == 25
      assert Admissions.challenge_cap(0) == 0
      assert Admissions.challenge_cap(1) == 1
      assert Admissions.challenge_cap(4) == 1
      assert Admissions.challenge_cap(5) == 2
      assert Admissions.challenge_cap(8) == 2
      assert Admissions.challenge_cap(100) == 25
    end

    test "one account suspends at most its share, and the rest queue" do
      author = account("cap-author")
      prolific = account("cap-prolific")

      memories =
        for index <- 1..8, do: admitted(author, "sys:cap-#{index}")

      # Written latest-first, so the challenges that take effect are chosen by
      # the records' own dates rather than by the order they arrived in.
      memories
      |> Enum.take(4)
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.each(fn {memory, index} ->
        challenge(prolific, memory, ~U[2026-08-25 12:00:00.000000Z] |> shift(index))
      end)

      statuses = Admissions.statuses()
      suspended = for {id, "suspended"} <- statuses, do: id

      assert Enum.sort(suspended) ==
               memories |> Enum.take(2) |> Enum.map(& &1.id) |> Enum.sort()

      # Equal inputs, equal outcomes.
      assert Admissions.statuses() == statuses
    end

    test "the cap is per account, not across the store" do
      author = account("cap-per-account-author")
      one = account("cap-per-account-one")
      two = account("cap-per-account-two")

      memories = for index <- 1..8, do: admitted(author, "sys:cap-account-#{index}")

      [first, second, third, fourth | _rest] = memories

      challenge(one, first, ~U[2026-08-25 12:00:00.000000Z])
      challenge(one, second, ~U[2026-08-25 12:00:01.000000Z])
      challenge(one, third, ~U[2026-08-25 12:00:02.000000Z])
      challenge(two, fourth, ~U[2026-08-25 12:00:03.000000Z])

      suspended = for {id, "suspended"} <- Admissions.statuses(), into: MapSet.new(), do: id

      assert MapSet.equal?(suspended, MapSet.new([first.id, second.id, fourth.id]))
    end

    test "several challenges against one memory spend one slot, not several" do
      author = account("cap-same-memory-author")
      prolific = account("cap-same-memory-prolific")

      memories = for index <- 1..8, do: admitted(author, "sys:cap-same-#{index}")
      [first, second | _rest] = memories

      challenge(prolific, first, ~U[2026-08-25 12:00:00.000000Z], "receipt:0a11")
      challenge(prolific, first, ~U[2026-08-25 12:00:01.000000Z], "receipt:0b22")
      challenge(prolific, second, ~U[2026-08-25 12:00:02.000000Z], "receipt:0c33")

      suspended = for {id, "suspended"} <- Admissions.statuses(), into: MapSet.new(), do: id

      assert MapSet.equal?(suspended, MapSet.new([first.id, second.id]))
    end

    # A challenge that suspends nothing spends nothing. Otherwise the cheapest
    # way past the cap would be to challenge rows nobody admitted.
    test "a challenge against a claim that is not admitted spends no budget" do
      author = account("cap-unadmitted-author")
      prolific = account("cap-unadmitted-prolific")

      memories = for index <- 1..8, do: admitted(author, "sys:cap-unadmitted-#{index}")
      [first, second | _rest] = memories

      {:ok, proposed} =
        Memories.create(author, candidate(%{"slug" => "sys:cap-unadmitted-candidate"}))

      challenge(prolific, proposed, ~U[2026-08-25 11:00:00.000000Z])
      challenge(prolific, first, ~U[2026-08-25 12:00:00.000000Z])
      challenge(prolific, second, ~U[2026-08-25 12:00:01.000000Z])

      suspended = for {id, "suspended"} <- Admissions.statuses(), into: MapSet.new(), do: id

      assert MapSet.equal?(suspended, MapSet.new([first.id, second.id]))
      assert Admissions.status(proposed) == "candidate"
    end

    test "a queued challenge takes effect once an earlier one is refuted" do
      author = account("cap-queue-author")
      prolific = account("cap-queue-prolific")
      resolving = steward()

      memories = for index <- 1..4, do: admitted(author, "sys:cap-queue-#{index}")
      [first, second | _rest] = memories

      one = challenge(prolific, first, ~U[2026-08-25 12:00:00.000000Z])
      _two = challenge(prolific, second, ~U[2026-08-25 12:00:01.000000Z])

      # Four admitted claims, so the cap is one.
      assert Admissions.status(first) == "suspended"
      assert Admissions.status(second) == "admitted"

      {:ok, _refutation} =
        Admissions.refute(resolving, one.id, %{"ground" => "The first ground does not stand."})

      assert Admissions.status(first) == "admitted"
      assert Admissions.status(second) == "suspended"
    end
  end

  # The point of the whole exercise. A backfill, an import, and a correction all
  # break the convenient case where records arrive in the order they happened,
  # so the derivation must not depend on it.
  describe "order independence" do
    test "every permutation of one record set derives the same statuses" do
      author = account("order-author")
      reader = account("order-reader")
      resolving = steward()

      {:ok, first} = Memories.create(author, candidate(%{"slug" => "sys:order-first"}))
      {:ok, second} = Memories.create(author, candidate(%{"slug" => "sys:order-second"}))

      # Timestamps deliberately at odds with any insertion order: the second
      # verdict on `first` is dated before nothing in particular, and the
      # refutation is dated *earlier* than the challenge it resolves, which is
      # the out-of-order case a backfill actually produces.
      against_first = challenge_record(reader, first, ~U[2026-08-25 11:00:00.000000Z], evidence())

      records = [
        verdict_record(resolving, first, "rejected", ~U[2026-08-25 10:00:00.000000Z]),
        verdict_record(resolving, first, "admitted", ~U[2026-08-25 10:00:05.000000Z]),
        verdict_record(resolving, second, "admitted", ~U[2026-08-25 10:00:02.000000Z]),
        against_first,
        challenge_record(
          reader,
          second,
          ~U[2026-08-25 11:00:01.000000Z],
          evidence("receipt:0b22")
        ),
        refutation_record(resolving, first, against_first, ~U[2026-08-25 09:00:00.000000Z])
      ]

      expected = %{first.id => "admitted", second.id => "suspended"}

      derived =
        for permutation <- permutations(records) do
          Repo.delete_all(Admission)
          insert_records(permutation)
          Admissions.statuses()
        end

      assert length(derived) == 720
      assert Enum.uniq(derived) == [expected]
    end
  end

  describe "the constraints hold around the changeset" do
    setup do
      author = account("constraint-author")
      %{author: author, memory: admitted(author, "sys:constraints")}
    end

    test "a challenge with an empty evidence list is refused by the database", context do
      assert_raise Ecto.ConstraintError, ~r/memory_admissions_shape/, fn ->
        around_the_changeset(%{
          memory_id: context.memory.id,
          author_id: context.author.id,
          role: "challenge",
          slug: "chl:" <> context.memory.id,
          ground: @ground,
          evidence_refs: []
        })
      end
    end

    test "a challenge whose evidence names no digest is refused", context do
      assert_raise Ecto.ConstraintError, ~r/memory_admissions_shape/, fn ->
        around_the_changeset(%{
          memory_id: context.memory.id,
          author_id: context.author.id,
          role: "challenge",
          slug: "chl:" <> context.memory.id,
          ground: @ground,
          evidence_refs: [%{"kind" => "url", "ref" => "https://openagents.com/"}]
        })
      end
    end

    test "a challenge under the wrong slug is refused", context do
      assert_raise Ecto.ConstraintError, ~r/memory_admissions_shape/, fn ->
        around_the_changeset(%{
          memory_id: context.memory.id,
          author_id: context.author.id,
          role: "challenge",
          slug: "chl:not-this-memory",
          ground: @ground
        })
      end
    end

    test "an admission carrying evidence is refused", context do
      assert_raise Ecto.ConstraintError, ~r/memory_admissions_shape/, fn ->
        around_the_changeset(%{
          memory_id: context.memory.id,
          author_id: context.author.id,
          role: "admission",
          verdict: "admitted",
          slug: "adm:" <> context.memory.id,
          ground: @ground,
          evidence_refs: evidence()
        })
      end
    end

    # `challenge_role` is what lets the foreign key insist that `challenge_id`
    # names a challenge. A null there would leave the foreign key unchecked, so
    # the shape constraint is what refuses it.
    test "a refutation with no challenge_role is refused", context do
      challenge = challenge(context.author, context.memory, ~U[2026-08-25 12:00:00.000000Z])

      assert_raise Ecto.ConstraintError, ~r/memory_admissions_shape/, fn ->
        around_the_changeset(%{
          memory_id: context.memory.id,
          author_id: context.author.id,
          role: "refutation",
          challenge_id: challenge.id,
          slug: "ref:" <> challenge.id,
          ground: "Resolved."
        })
      end
    end

    test "a refutation naming an admission record is refused", context do
      [verdict] = Enum.filter(Admissions.list(context.memory), &(&1.role == "admission"))

      assert_raise Ecto.ConstraintError, ~r/memory_admissions_challenge_fkey/, fn ->
        around_the_changeset(%{
          memory_id: context.memory.id,
          author_id: context.author.id,
          role: "refutation",
          challenge_id: verdict.id,
          challenge_role: "challenge",
          slug: "ref:" <> verdict.id,
          ground: "Resolved."
        })
      end
    end

    test "a refutation naming a challenge against another memory is refused", context do
      other = admitted(context.author, "sys:constraints-other")
      challenge = challenge(context.author, other, ~U[2026-08-25 12:00:00.000000Z])

      assert_raise Ecto.ConstraintError, ~r/memory_admissions_challenge_fkey/, fn ->
        around_the_changeset(%{
          memory_id: context.memory.id,
          author_id: context.author.id,
          role: "refutation",
          challenge_id: challenge.id,
          challenge_role: "challenge",
          slug: "ref:" <> challenge.id,
          ground: "Resolved."
        })
      end
    end
  end

  # MEMORY-001 and MEMORY-010, unchanged. Challenge and refutation are about
  # what a status derives to, not about what any session sees, and every one of
  # these states reaches the same number of turns: none.
  describe "the recall boundary" do
    test "a suspended, a challenged, and an admitted memory all surface to nobody" do
      author = account("recall-author")
      reader = account("recall-reader")

      suspended = admitted(author, "sys:recall-suspended")
      plain = admitted(author, "sys:recall-admitted")

      {:ok, _challenge} =
        Admissions.challenge(reader, suspended.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      assert Admissions.status(suspended) == "suspended"
      assert Admissions.status(plain) == "admitted"

      for account <- [author, reader] do
        assert %Recall{memories: []} =
                 Memories.recall(account, "the inference gateway returned 402")
      end
    end

    test "and a challenge writes nothing into the buckets recall does read" do
      author = account("recall-buckets-author")
      reader = account("recall-buckets-reader")

      memory = admitted(author, "sys:recall-buckets")

      {:ok, _challenge} =
        Admissions.challenge(reader, memory.id, %{
          "ground" => @ground,
          "evidence_refs" => evidence("receipt:0a11")
        })

      {:ok, asked} = Memories.create(reader, %{"body" => "I use pnpm, not npm."})

      %Recall{memories: recalled} = Memories.recall(reader, "install the deps")

      assert Enum.map(recalled, & &1.id) == [asked.id]
      assert Memories.list(reader, bucket: "system") == []
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp shift(%DateTime{} = at, seconds), do: DateTime.add(at, seconds, :second)

  # A challenge dated deliberately, which is what the cap ranks by.
  defp challenge(user, memory, at, ref \\ "receipt:0a11") do
    Repo.insert!(challenge_record(user, memory, at, evidence(ref)))
  end

  defp challenge_record(user, memory, at, refs) do
    %Admission{
      id: Ecto.UUID.generate(),
      memory_id: memory.id,
      memory_bucket: "system",
      author_id: user.id,
      role: "challenge",
      slug: "chl:" <> memory.id,
      ground: @ground,
      evidence_refs: refs,
      inserted_at: at
    }
  end

  defp verdict_record(user, memory, verdict, at) do
    %Admission{
      id: Ecto.UUID.generate(),
      memory_id: memory.id,
      memory_bucket: "system",
      author_id: user.id,
      role: "admission",
      verdict: verdict,
      slug: "adm:" <> memory.id,
      ground: "Read the receipt.",
      inserted_at: at
    }
  end

  defp refutation_record(user, memory, challenge, at) do
    %Admission{
      id: Ecto.UUID.generate(),
      memory_id: memory.id,
      memory_bucket: "system",
      author_id: user.id,
      role: "refutation",
      challenge_id: challenge.id,
      challenge_role: "challenge",
      slug: "ref:" <> challenge.id,
      ground: "The ground does not stand.",
      inserted_at: at
    }
  end

  # The foreign key forbids a refutation reaching the table before the
  # challenge it names, so a permutation is applied within each group rather
  # than across them. That is not a weakening of the property: what the
  # derivation must not read is the records' arrival order, and the refutation
  # here is *dated* two hours before its challenge, which is the disagreement
  # between arrival and date that a backfill actually produces.
  defp insert_records(records) do
    {independent, dependent} = Enum.split_with(records, &(&1.role != "refutation"))
    Enum.each(independent ++ dependent, &Repo.insert!/1)
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for element <- list, rest <- permutations(list -- [element]), do: [element | rest]
  end
end
