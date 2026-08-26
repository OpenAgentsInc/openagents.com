defmodule OpenAgents.Memories.PromotionTest do
  @moduledoc """
  The knowledge-base boundary, and the one place it is enforced.

  Specification section 8 says the knowledge base wins when both rails speak
  about the same claim. Since the cloud re-base the two rails are assembled in
  different processes, so this store draws the line where a claim crosses it —
  at promotion — rather than where the notes are assembled. The reasoning is in
  `docs/memory/knowledge-base-boundary.md`; what these tests pin is that the
  line actually holds.

  **The collision test is identity, never text.** Two claims are the same claim
  across the rails exactly when a promotion tombstone on the memory's slug names
  the stance, and that link is recorded by a steward at promotion. Prose overlap
  is not a collision here, and the near-miss tests below are the half that says
  so: a memory whose words match a stance's, and even one whose body quotes the
  stance id, stays live and stays eligible, because nobody recorded that they
  are the same claim.

  What makes the resolution real rather than advisory is that a promoted claim
  cannot reach recall by any route. The row it came from is superseded, so it is
  not live. The tombstone that replaced it can never be admitted, because the
  composite foreign key `(memory_id, memory_promoted)` refuses every record that
  names it — and recall surfaces admitted rows only (specification 7.1). Both
  halves are database predicates, so they hold for a second write path as well
  as for the one this module offers, which is why the constraint tests insert
  around the changeset.
  """
  use OpenAgents.DataCase, async: true

  alias OpenAgents.Memories
  alias OpenAgents.Memories.{Admissions, Memory, Promotions}

  # The owner account is an operator by definition (`@owner_github_id`), so a
  # steward needs no configuration change and these tests stay async.
  @owner_github_id 14_167_547

  @stance "gateway-402-retired-model"

  defp account(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()

    upsert(github_id, "promote-" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 12)))
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

  defp evidence do
    [%{"kind" => "receipt", "ref" => "receipt:4f1c", "digest" => "sha256:9ab3"}]
  end

  defp stance_evidence do
    [
      %{
        "kind" => "url",
        "ref" => "https://openagents.com/OpenAgentsInc/openagents/kb/stances.json",
        "digest" => "sha256:7897da0a"
      }
    ]
  end

  defp candidate(overrides \\ %{}) do
    Map.merge(
      %{
        "bucket" => "system",
        "slug" => "sys:gateway-402-retired-model",
        "body" =>
          "A 402 from the inference gateway usually means the default model was " <>
            "retired upstream. Check gateway status before bisecting local lanes.",
        "entity" => "inference-gateway",
        "tier" => "ledger",
        "as_of" => ~D[2026-08-25],
        "admission" => "candidate",
        "evidence_refs" => evidence()
      },
      overrides
    )
  end

  # An admitted system claim: written by an author, admitted by a steward.
  defp admitted_claim(key, overrides \\ %{}) do
    author = account(key)
    {:ok, memory} = Memories.create(author, candidate(overrides))

    {:ok, _verdict} =
      Admissions.record(steward(), memory.id, %{
        "verdict" => "admitted",
        "ground" => "The receipt shows the retirement and the 402 together."
      })

    memory
  end

  defp promotion(overrides \\ %{}) do
    Map.merge(
      %{
        "stance" => @stance,
        "slug" => "sys:gateway-402-retired-model",
        "evidence_refs" => stance_evidence()
      },
      overrides
    )
  end

  # Specification 7.1's eligibility filter, written here rather than imported.
  #
  # Recall does not read the system bucket yet — the issue that builds the
  # ranking owns that — so these tests model the predicate the specification
  # states: a system memory reaches a note when it is live and its derived
  # status is `admitted`. Writing it out is the point. A test that asserted
  # "the tombstone is not admitted" without saying what that buys would pin a
  # fact rather than the rule the fact serves.
  defp eligible?(%Memory{} = memory) do
    reread = Repo.get!(Memory, memory.id)

    is_nil(reread.superseded_by_id) and Admissions.status(reread) == "admitted"
  end

  # A row assembled as a struct rather than through `changeset/2`. The second
  # route the constraints exist for.
  defp around_the_changeset(user, overrides) do
    fields =
      Map.merge(
        %{
          user_id: user.id,
          bucket: "system",
          body: "Written around the write path.",
          slug: "sys:around-the-write-path",
          tier: "ledger",
          as_of: ~D[2026-08-25],
          admission: "candidate",
          evidence_refs: evidence()
        },
        overrides
      )

    Repo.insert(struct(Memory, fields))
  end

  describe "a promotion tombstone" do
    test "supersedes the claim and names the stance it went to" do
      claim = admitted_claim("promote-shape")

      assert {:ok, tombstone} = Promotions.promote(steward(), claim.id, promotion())

      assert tombstone.bucket == "system"
      assert tombstone.stance == @stance
      assert tombstone.promoted == true
      assert tombstone.body =~ @stance
      assert tombstone.body == Promotions.body(@stance)
      assert tombstone.admission == "candidate"
      assert tombstone.tier == Promotions.tier()
      assert Memory.promoted?(tombstone)

      assert Repo.get!(Memory, claim.id).superseded_by_id == tombstone.id
    end

    test "a body that does not name its stance is refused at the table" do
      author = account("promote-body-names-stance")

      assert_raise Ecto.ConstraintError, ~r/memories_system_shape/, fn ->
        around_the_changeset(author, %{
          stance: @stance,
          body: "Promoted somewhere, but this body never says where."
        })
      end
    end

    test "a malformed stance id is refused" do
      claim = admitted_claim("promote-stance-format")

      for malformed <- ["Gateway-402", "gateway 402", "gateway--402", "-gateway", "kb/stance"] do
        assert {:error, changeset} =
                 Promotions.promote(steward(), claim.id, promotion(%{"stance" => malformed}))

        assert Map.has_key?(errors_on(changeset), :stance),
               "#{inspect(malformed)} was accepted as a stance id"
      end

      # A blank name is refused before the changeset, which would cast it to
      # absence and write an ordinary supersession under a promotion's body.
      assert {:error, :stance_required} =
               Promotions.promote(steward(), claim.id, promotion(%{"stance" => "   "}))

      assert Repo.get!(Memory, claim.id).superseded_by_id == nil
    end

    test "a stance belongs only to a system memory" do
      author = account("promote-account-scoped")

      assert {:error, changeset} =
               Memories.create(author, %{
                 "body" => "I prefer pnpm, and the stance is gateway-402-retired-model.",
                 "stance" => @stance
               })

      assert Map.has_key?(errors_on(changeset), :stance)

      assert_raise Ecto.ConstraintError, ~r/memories_system_shape/, fn ->
        around_the_changeset(author, %{
          bucket: "user",
          slug: nil,
          tier: nil,
          as_of: nil,
          admission: nil,
          evidence_refs: nil,
          stance: @stance
        })
      end
    end
  end

  describe "the knowledge base wins the claims it was promoted for" do
    # The whole rule, in one test: before promotion the memory rail speaks,
    # after promotion it does not, and nothing was deleted to make that true.
    test "a promoted claim leaves recall and the claim's chain is kept" do
      claim = admitted_claim("promote-drains")

      assert eligible?(claim), "an admitted live claim should reach recall"

      {:ok, tombstone} = Promotions.promote(steward(), claim.id, promotion())

      refute eligible?(claim), "a promoted claim must not reach recall"
      refute eligible?(tombstone), "a tombstone must not reach recall"

      # Superseded, not deleted: the claim, its evidence, and its admission
      # record are all still readable.
      assert %Memory{} = Repo.get!(Memory, claim.id)
      assert Admissions.status(claim) == "admitted"
      assert Admissions.list(claim) != []
    end

    # `:not_found` rather than a changeset error, because the composite foreign
    # key is what refuses this and the module reports a key violation as
    # absence: a steward who names a tombstone learns that it is not admissible,
    # and nothing more.
    test "nothing can admit a tombstone, so nothing can make one eligible" do
      claim = admitted_claim("promote-unadmittable")
      {:ok, tombstone} = Promotions.promote(steward(), claim.id, promotion())

      assert {:error, :not_found} =
               Admissions.record(steward(), tombstone.id, %{
                 "verdict" => "admitted",
                 "ground" => "Trying to admit the tombstone itself."
               })

      assert Admissions.status(tombstone) == "candidate"
      refute eligible?(tombstone)
    end

    test "a tombstone is a pointer rather than a claim, so it takes no records" do
      claim = admitted_claim("promote-no-records")
      {:ok, tombstone} = Promotions.promote(steward(), claim.id, promotion())

      assert {:error, :not_found} =
               Admissions.challenge(account("promote-challenger"), tombstone.id, %{
                 "ground" => "The stance is wrong.",
                 "evidence_refs" => evidence()
               })

      assert Admissions.list(tombstone) == []
    end

    # The record path is refused by the database, so a second write path is
    # refused too rather than merely unattempted by the code that exists today.
    test "a record naming a tombstone is refused around the changeset" do
      claim = admitted_claim("promote-around-the-record-path")
      {:ok, tombstone} = Promotions.promote(steward(), claim.id, promotion())

      assert_raise Ecto.ConstraintError, ~r/memory_admissions_promotion_fkey/, fn ->
        Repo.insert(
          struct(OpenAgents.Memories.Admission, %{
            memory_id: tombstone.id,
            memory_bucket: "system",
            memory_promoted: false,
            author_id: steward().id,
            slug: "adm:" <> tombstone.id,
            role: "admission",
            verdict: "admitted",
            ground: "Written around the record path.",
            inserted_at: DateTime.utc_now()
          })
        )
      end
    end
  end

  describe "a near miss is not a collision" do
    # The claim this store would call "the same claim" is the one a promotion
    # names. Shared vocabulary is not that, and neither is quoting the stance id
    # in prose — otherwise a memory *about* a stance would silence itself.
    test "a memory that shares the promoted claim's words stays eligible" do
      promoted = admitted_claim("promote-near-miss-target")
      {:ok, _tombstone} = Promotions.promote(steward(), promoted.id, promotion())

      neighbour =
        admitted_claim("promote-near-miss-neighbour", %{
          "slug" => "sys:gateway-402-quota-exhausted",
          "body" =>
            "A 402 from the inference gateway can also mean the account's " <>
              "gateway quota is exhausted. Check the balance before the model status."
        })

      assert neighbour.stance == nil
      refute Memory.promoted?(neighbour)
      assert eligible?(neighbour), "a distinct claim must survive its neighbour's promotion"
    end

    test "a memory that quotes the stance id is not thereby promoted" do
      promoted = admitted_claim("promote-near-miss-quote-target")
      {:ok, _tombstone} = Promotions.promote(steward(), promoted.id, promotion())

      quoting =
        admitted_claim("promote-near-miss-quote", %{
          "slug" => "sys:kb-corpus-rebuild",
          "body" =>
            "Editing the #{@stance} stance needs `node build-kb.mjs` and a " <>
              "rebuild before the digest is re-pinned; the corpus is compiled, not read."
        })

      assert quoting.body =~ @stance
      assert quoting.stance == nil
      assert eligible?(quoting), "quoting a stance id is not a promotion"
    end

    # Same claim, same slug, one promotion: the tombstone drains the row it
    # names and nothing else. Draining by slug would take a cross-account read
    # of `memories`, which MEMORY-010 keeps out of this store.
    test "promotion drains the row it names, not every row sharing its slug" do
      promoted = admitted_claim("promote-slug-a")
      sibling = admitted_claim("promote-slug-b", %{"as_of" => ~D[2026-08-24]})

      assert promoted.slug == sibling.slug

      {:ok, _tombstone} = Promotions.promote(steward(), promoted.id, promotion())

      refute eligible?(promoted)
      assert eligible?(sibling), "only the named row is drained"
    end
  end

  describe "who promotes" do
    test "only a steward" do
      author = account("promote-author")
      {:ok, memory} = Memories.create(author, candidate())

      assert {:error, :steward_required} = Promotions.promote(author, memory.id, promotion())
      assert Repo.get!(Memory, memory.id).superseded_by_id == nil
    end

    test "a promotion names a stance or it is not a promotion" do
      claim = admitted_claim("promote-stance-required")

      assert {:error, :stance_required} =
               Promotions.promote(steward(), claim.id, Map.delete(promotion(), "stance"))

      assert Repo.get!(Memory, claim.id).superseded_by_id == nil
    end

    test "a target that is not a live system memory is refused without a read" do
      claim = admitted_claim("promote-twice")
      {:ok, _tombstone} = Promotions.promote(steward(), claim.id, promotion())

      assert {:error, :not_supersedable} = Promotions.promote(steward(), claim.id, promotion())

      assert {:error, :not_supersedable} =
               Promotions.promote(steward(), Ecto.UUID.generate(), promotion())

      assert {:error, :not_supersedable} =
               Promotions.promote(steward(), "not-a-uuid", promotion())
    end

    # A promotion is a steward's correction on the target's slug, and the
    # specification names that as the second resolution path for a challenge.
    test "promoting resolves the open challenges on the claim" do
      claim = admitted_claim("promote-resolves-challenges")

      {:ok, _challenge} =
        Admissions.challenge(account("promote-challenger-two"), claim.id, %{
          "ground" => "The 402 is a quota error, not a retirement.",
          "evidence_refs" => evidence()
        })

      assert Admissions.status(claim) == "suspended"

      assert {:ok, _tombstone} = Promotions.promote(steward(), claim.id, promotion())

      assert Admissions.status(claim) == "admitted"
      assert Enum.any?(Admissions.list(claim), &(&1.role == "refutation"))
    end
  end
end
