defmodule OpenAgents.Memories.SystemMemoryTest do
  @moduledoc """
  The system bucket: what it refuses, what a status is derived from, who may
  admit, who may correct, and what it is still not allowed to reach.

  Four properties carry the weight here, and each of them is the kind that
  holds until somebody adds a second route to the same table.

  An evidence-free candidate is refused **by the database**, so these tests
  insert around the changeset rather than through it. A validation refused only
  in `changeset/2` is an application filter, and MEMORY-004's discipline is
  that a boundary is a predicate the store enforces.

  Status is derived from the admission records, never read from the author's
  own field, so an author who writes `admitted` on their own row is still
  proposing.

  Only a steward admits, and only the author or a steward corrects. A caller
  with no standing is refused without learning anything about the row.

  And the bucket surfaces to nobody. A system memory that is stored and
  admitted but recalled by no session is the shippable state; recall reaching
  it would be cross-account recall, which MEMORY-001 and MEMORY-010 forbid.
  """
  use OpenAgents.DataCase, async: true

  alias OpenAgents.Memories
  alias OpenAgents.Memories.{Admission, Admissions, Memory, Recall}

  # The owner account is an operator by definition (`@owner_github_id`), so a
  # steward needs no configuration change and these tests stay async.
  @owner_github_id 14_167_547

  defp account(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()

    upsert(github_id, "sysmem-" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 12)))
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

  # A row assembled as a struct rather than through `changeset/2`. This is the
  # second route the constraint exists for.
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

  describe "the system fields" do
    test "round-trip on a memory row" do
      author = account("system-round-trip")

      assert {:ok, memory} = Memories.create(author, candidate())

      reread = Repo.get!(Memory, memory.id)

      assert reread.bucket == "system"
      assert reread.slug == "sys:gateway-402-retired-model"
      assert reread.entity == "inference-gateway"
      assert reread.tier == "ledger"
      assert reread.as_of == ~D[2026-08-25]
      assert reread.admission == "candidate"

      assert reread.evidence_refs == [
               %{"kind" => "receipt", "ref" => "receipt:4f1c", "digest" => "sha256:9ab3"}
             ]
    end

    # `as_of` dates the claim and `inserted_at` orders the chain, so a claim
    # observed true last year is still written today and still reads as dated.
    test "as_of is the claim's date, not the row's" do
      author = account("system-as-of")

      {:ok, memory} = Memories.create(author, candidate(%{"as_of" => ~D[2025-01-09]}))

      assert memory.as_of == ~D[2025-01-09]
      assert DateTime.to_date(memory.inserted_at) != memory.as_of
    end

    test "a system memory needs a slug, a tier, a date, and an admission" do
      author = account("system-required")

      for {field, key} <- [{"slug", :slug}, {"tier", :tier}, {"as_of", :as_of}] do
        assert {:error, changeset} = Memories.create(author, Map.put(candidate(), field, nil))
        assert Map.has_key?(errors_on(changeset), key)
      end

      assert {:error, changeset} = Memories.create(author, Map.put(candidate(), "admission", nil))
      assert Map.has_key?(errors_on(changeset), :admission)
    end

    test "the slug carries the sys: prefix" do
      author = account("system-slug")

      assert {:error, changeset} =
               Memories.create(author, candidate(%{"slug" => "gateway-402"}))

      assert %{slug: _refused} = errors_on(changeset)
    end

    test "a user or learned row carries none of them" do
      author = account("system-fields-elsewhere")

      assert {:error, changeset} =
               Memories.create(author, %{
                 "body" => "I use pnpm.",
                 "bucket" => "user",
                 "tier" => "ledger"
               })

      assert %{tier: _refused} = errors_on(changeset)

      assert {:error, changeset} =
               Memories.create(author, %{
                 "body" => "The migration runs first.",
                 "bucket" => "learned",
                 "evidence_refs" => evidence()
               })

      assert %{evidence_refs: _refused} = errors_on(changeset)
    end

    test "an ordinary memory is unaffected" do
      author = account("system-unaffected")

      assert {:ok, plain} = Memories.create(author, %{"body" => "I use pnpm, not npm."})

      assert plain.bucket == "user"
      assert plain.slug == nil
      assert plain.tier == nil
      assert plain.as_of == nil
      assert plain.admission == nil
      assert plain.evidence_refs == nil
    end
  end

  describe "evidence is unrepresentable when absent" do
    test "the write path refuses a candidate with no evidence" do
      author = account("evidence-write-path")

      assert {:error, changeset} =
               Memories.create(author, candidate(%{"evidence_refs" => []}))

      assert %{evidence_refs: _refused} = errors_on(changeset)

      assert {:error, changeset} =
               Memories.create(author, candidate(%{"evidence_refs" => nil}))

      assert %{evidence_refs: _refused} = errors_on(changeset)
    end

    test "the write path refuses an evidence ref missing its digest or its kind" do
      author = account("evidence-shape")

      for broken <- [
            %{"kind" => "receipt", "ref" => "receipt:4f1c"},
            %{"kind" => "rumour", "ref" => "receipt:4f1c", "digest" => "sha256:9ab3"},
            %{"kind" => "url", "ref" => "", "digest" => "sha256:9ab3"}
          ] do
        assert {:error, changeset} =
                 Memories.create(author, candidate(%{"evidence_refs" => [broken]}))

        assert %{evidence_refs: _refused} = errors_on(changeset)
      end
    end

    # The point of the whole exercise: not "the changeset refuses it" but "the
    # table has no row shaped like that", so a second write path cannot reopen
    # the hole.
    test "the database refuses an evidence-free candidate inserted around the changeset" do
      author = account("evidence-constraint")

      assert_raise Ecto.ConstraintError, ~r/memories_system_shape/, fn ->
        around_the_changeset(author, %{evidence_refs: []})
      end

      assert_raise Ecto.ConstraintError, ~r/memories_system_shape/, fn ->
        around_the_changeset(author, %{evidence_refs: nil})
      end
    end

    test "the database refuses an evidence ref that names no digest" do
      author = account("evidence-constraint-shape")

      assert_raise Ecto.ConstraintError, ~r/memories_system_shape/, fn ->
        around_the_changeset(author, %{
          evidence_refs: [%{"kind" => "url", "ref" => "https://openagents.com/"}]
        })
      end
    end

    test "the database refuses a tier below ledger, around the changeset and through it" do
      author = account("tier-constraint")

      assert {:error, changeset} = Memories.create(author, candidate(%{"tier" => "pulse"}))
      assert %{tier: _refused} = errors_on(changeset)

      assert_raise Ecto.ConstraintError, ~r/memories_system_shape/, fn ->
        around_the_changeset(author, %{tier: "dark"})
      end
    end

    test "the database refuses system fields on a learned row" do
      author = account("bucket-constraint")

      assert_raise Ecto.ConstraintError, ~r/memories_system_shape/, fn ->
        around_the_changeset(author, %{bucket: "learned"})
      end
    end
  end

  describe "derived admission status" do
    test "a candidate with no record behind it is a candidate" do
      author = account("status-candidate")

      {:ok, memory} = Memories.create(author, candidate())

      assert Admissions.status(memory) == "candidate"
    end

    test "an author's self-claimed admitted still reads as a candidate" do
      author = account("status-self-claimed")

      {:ok, memory} = Memories.create(author, candidate(%{"admission" => "admitted"}))

      assert memory.admission == "admitted"
      assert Admissions.status(memory) == "candidate"
    end

    test "a steward's verdict is what the status is read from" do
      author = account("status-admitted")
      admitting = steward()

      {:ok, memory} = Memories.create(author, candidate())

      assert {:ok, record} =
               Admissions.record(admitting, memory.id, %{
                 "verdict" => "admitted",
                 "ground" => "The receipt shows the 402 and the retirement together."
               })

      assert record.slug == "adm:" <> memory.id
      assert record.role == "admission"
      assert record.author_id == admitting.id
      assert Admissions.status(memory) == "admitted"
    end

    test "a rejection reads as rejected, and a later verdict replaces an earlier one" do
      author = account("status-rejected")
      admitting = steward()

      {:ok, memory} = Memories.create(author, candidate())

      {:ok, _rejected} =
        Admissions.record(admitting, memory.id, %{
          "verdict" => "rejected",
          "ground" => "The digest does not match the receipt it names."
        })

      assert Admissions.status(memory) == "rejected"

      {:ok, _admitted} =
        Admissions.record(admitting, memory.id, %{
          "verdict" => "admitted",
          "ground" => "The author re-cited the receipt and the digest matches."
        })

      assert Admissions.status(memory) == "admitted"

      # Append-only: the reversal is a second record, not an edit of the first.
      assert Enum.map(Admissions.list(memory), & &1.verdict) == ["rejected", "admitted"]
    end

    test "a memory outside the system bucket has no admission status" do
      author = account("status-other-bucket")

      {:ok, plain} = Memories.create(author, %{"body" => "I use pnpm."})

      assert Admissions.status(plain) == nil
    end
  end

  describe "only a steward admits" do
    test "an ordinary account is refused" do
      author = account("admit-non-steward")
      other = account("admit-non-steward-other")

      {:ok, memory} = Memories.create(author, candidate())

      assert {:error, :steward_required} =
               Admissions.record(other, memory.id, %{
                 "verdict" => "admitted",
                 "ground" => "I say so."
               })

      # And the refusal changes nothing.
      assert Admissions.status(memory) == "candidate"
      assert Admissions.list(memory) == []
    end

    test "the author cannot admit their own candidate" do
      author = account("admit-self")

      {:ok, memory} = Memories.create(author, candidate())

      assert {:error, :steward_required} =
               Admissions.record(author, memory.id, %{
                 "verdict" => "admitted",
                 "ground" => "It is true."
               })
    end

    test "a record needs a verdict and a ground" do
      author = account("admit-shape")
      admitting = steward()

      {:ok, memory} = Memories.create(author, candidate())

      assert {:error, changeset} =
               Admissions.record(admitting, memory.id, %{"verdict" => "maybe", "ground" => "Hm."})

      assert %{verdict: _refused} = errors_on(changeset)

      assert {:error, changeset} =
               Admissions.record(admitting, memory.id, %{"verdict" => "admitted"})

      assert %{ground: _refused} = errors_on(changeset)
    end

    # The composite foreign key, not a read. A candidate outside the system
    # bucket is not admissible, and saying so costs no query across an account.
    test "a record naming a memory outside the system bucket is refused" do
      author = account("admit-wrong-bucket")
      admitting = steward()

      {:ok, plain} = Memories.create(author, %{"body" => "I use pnpm."})

      assert {:error, :not_found} =
               Admissions.record(admitting, plain.id, %{
                 "verdict" => "admitted",
                 "ground" => "Not a system memory."
               })

      assert Repo.aggregate(Admission, :count) == 0
    end

    test "a record naming no memory at all is refused" do
      admitting = steward()

      assert {:error, :not_found} =
               Admissions.record(admitting, "not-a-uuid", %{
                 "verdict" => "admitted",
                 "ground" => "Nothing."
               })

      assert {:error, :not_found} =
               Admissions.record(admitting, Ecto.UUID.generate(), %{
                 "verdict" => "admitted",
                 "ground" => "Nothing."
               })
    end
  end

  describe "supersession on a system slug" do
    test "the author corrects their own claim" do
      author = account("supersede-author")

      {:ok, wrong} = Memories.create(author, candidate())

      assert {:ok, right} =
               Admissions.supersede(
                 author,
                 wrong.id,
                 candidate(%{"body" => "A 402 is the retired-model signal. Check status first."})
               )

      assert Repo.get!(Memory, wrong.id).superseded_by_id == right.id
      assert right.user_id == author.id
    end

    test "a steward corrects another account's claim" do
      author = account("supersede-steward")
      correcting = steward()

      {:ok, wrong} = Memories.create(author, candidate())

      assert {:ok, right} =
               Admissions.supersede(
                 correcting,
                 wrong.id,
                 candidate(%{"body" => "The gateway 402s when the default model is retired."})
               )

      assert Repo.get!(Memory, wrong.id).superseded_by_id == right.id
      assert right.user_id == correcting.id
    end

    test "anyone else is refused, and the row is untouched" do
      author = account("supersede-stranger")
      stranger = account("supersede-stranger-other")

      {:ok, memory} = Memories.create(author, candidate())

      assert {:error, :not_supersedable} =
               Admissions.supersede(stranger, memory.id, candidate(%{"body" => "Mine now."}))

      assert Repo.get!(Memory, memory.id).superseded_by_id == nil

      # The refusal is a rollback, not a half-write: the replacement the
      # stranger proposed does not survive it.
      assert Memories.list(stranger, bucket: "system") == []
    end

    test "an already superseded claim is not superseded twice" do
      author = account("supersede-twice")

      {:ok, first} = Memories.create(author, candidate())
      {:ok, _second} = Admissions.supersede(author, first.id, candidate(%{"body" => "Second."}))

      assert {:error, :not_supersedable} =
               Admissions.supersede(author, first.id, candidate(%{"body" => "Third."}))
    end

    test "an unreadable target is refused rather than raised" do
      author = account("supersede-unreadable")

      assert {:error, :not_supersedable} =
               Admissions.supersede(author, "not-a-uuid", candidate())
    end
  end

  # MEMORY-001 and MEMORY-010. The whole bucket is stored and admitted, and
  # surfaced to nobody. Widening this is a privacy decision that belongs to the
  # recall issue, and these assertions are what make it a decision rather than
  # a side effect.
  describe "the recall boundary" do
    test "an admitted system memory never reaches another account's turn" do
      author = account("recall-boundary-author")
      reader = account("recall-boundary-reader")
      admitting = steward()

      {:ok, memory} = Memories.create(author, candidate())

      {:ok, _record} =
        Admissions.record(admitting, memory.id, %{
          "verdict" => "admitted",
          "ground" => "The receipt supports the claim."
        })

      assert Admissions.status(memory) == "admitted"

      assert %Recall{memories: []} =
               Memories.recall(reader, "the inference gateway returned 402")
    end

    test "nor its own author's turn" do
      author = account("recall-boundary-own")
      admitting = steward()

      {:ok, memory} = Memories.create(author, candidate())

      {:ok, _record} =
        Admissions.record(admitting, memory.id, %{
          "verdict" => "admitted",
          "ground" => "The receipt supports the claim."
        })

      %Recall{memories: recalled} =
        Memories.recall(author, "the inference gateway returned 402")

      assert recalled == []
    end

    test "and it does not crowd out the buckets recall does read" do
      author = account("recall-boundary-mixed")

      {:ok, _system} = Memories.create(author, candidate())
      {:ok, asked} = Memories.create(author, %{"body" => "I use pnpm, not npm."})

      %Recall{memories: recalled, dropped: dropped} =
        Memories.recall(author, "install the deps")

      assert Enum.map(recalled, & &1.id) == [asked.id]
      assert dropped == 0
    end

    test "the author still reads their own system memories through the store" do
      author = account("recall-boundary-list")

      {:ok, memory} = Memories.create(author, candidate())

      assert Enum.map(Memories.list(author, bucket: "system"), & &1.id) == [memory.id]
      assert {:ok, %Memory{id: id}} = Memories.fetch(author, memory.id)
      assert id == memory.id
    end

    test "and another account's system memory is absent rather than forbidden" do
      author = account("recall-boundary-fetch")
      reader = account("recall-boundary-fetch-other")

      {:ok, memory} = Memories.create(author, candidate())

      assert {:error, :not_found} = Memories.fetch(reader, memory.id)
      assert Memories.list(reader, bucket: "system") == []
    end
  end
end
