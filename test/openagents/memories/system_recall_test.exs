defmodule OpenAgents.Memories.SystemRecallTest do
  @moduledoc """
  The one recall path that crosses an account boundary: what it takes to turn
  it on, what it lets through when it is on, and what it changes when it is
  off.

  Four properties carry the weight.

  **Off is off, and off is the default.** The flag is `false` in
  `config/config.exs` and declared `false` in the production and staging
  profiles, and with it off an account's own recall is not merely similar to
  what it was before this bucket had a recall path — it is byte for byte the
  same. That is proved by comparison here rather than asserted: the same
  account's recall is captured with no system store behind it, an admitted
  system store is then written, and the two results are compared whole.

  **Eligibility is derived, never claimed.** A row surfaces only when the
  admission records derive `admitted` for it. A candidate, a rejected row, a
  suspended row, a superseded row, and a row whose own `admission` column says
  `admitted` with no steward behind it all reach nobody.

  **The caps bound volume, not truth.** One account that wrote most of the
  admitted store still fills at most its quarter of a message's pool and at
  most one line of a note.

  **It is deterministic.** Equal inputs give equal notes, every time.
  """
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Memories
  alias OpenAgents.Memories.{Admissions, Memory, Note, Recall, SystemRecall}

  # The owner account is an operator by definition, so a steward needs no
  # configuration change.
  @owner_github_id 14_167_547

  setup do
    original = Application.get_env(:openagents, :memory_recall)
    on_exit(fn -> Application.put_env(:openagents, :memory_recall, original) end)
    :ok
  end

  defp surfacing(enabled?) do
    settings =
      :openagents
      |> Application.get_env(:memory_recall, [])
      |> Keyword.put(:system_bucket_enabled, enabled?)

    Application.put_env(:openagents, :memory_recall, settings)
  end

  defp account(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()

    upsert(github_id, "sysrec-" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 12)))
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

  # A row assembled as a struct rather than through `changeset/2`, so the tier
  # floor is proved against the table rather than against the validation.
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

  # Written, then judged. The verdict is a steward's record, which is the only
  # thing `status/1` reads.
  defp admitted(author, overrides \\ %{}) do
    {:ok, memory} = Memories.create(author, candidate(overrides))

    {:ok, _record} =
      Admissions.record(steward(), memory.id, %{
        "verdict" => "admitted",
        "ground" => "The receipt supports the claim."
      })

    memory
  end

  @turn "the inference gateway returned 402 on the default model"

  describe "the flag, off" do
    test "is the default this repository ships" do
      refute SystemRecall.enabled?()
    end

    test "surfaces an admitted system memory to nobody, including its author" do
      author = account("off-author")
      reader = account("off-reader")

      memory = admitted(author)
      assert Admissions.status(memory) == "admitted"

      assert %Recall{memories: []} = Memories.recall(reader, @turn)
      assert %Recall{memories: []} = Memories.recall(author, @turn)
    end

    test "issues no query for the bucket at all" do
      assert SystemRecall.pool(@turn) == []
    end

    test "leaves user and learned recall byte for byte what it was" do
      reader = account("off-identical")
      author = account("off-identical-author")

      {:ok, _asked} = Memories.create(reader, %{"body" => "I use pnpm, not npm."})

      {:ok, _learned} =
        Memories.create(reader, %{
          "body" => "The inference gateway returned 402 during the last deploy.",
          "bucket" => "learned"
        })

      before = Memories.recall(reader, @turn)
      before_note = Note.render(before)

      # An admitted store, written by another account and by this one, is now
      # behind the same query.
      _theirs = admitted(author)
      _mine = admitted(reader, %{"slug" => "sys:precommit-installs-the-push-guard"})

      after_store = Memories.recall(reader, @turn)

      assert after_store == before
      assert Note.render(after_store) == before_note
      refute before_note == nil
    end
  end

  describe "the flag, on" do
    setup do
      surfacing(true)
      :ok
    end

    test "an admitted ledger memory reaches an account that did not write it" do
      author = account("on-author")
      reader = account("on-reader")

      memory = admitted(author)

      %Recall{memories: recalled} = Memories.recall(reader, @turn)

      assert Enum.map(recalled, & &1.id) == [memory.id]
    end

    test "and reaches its own author too" do
      author = account("on-own-author")

      memory = admitted(author)

      %Recall{memories: recalled} = Memories.recall(author, @turn)

      assert Enum.map(recalled, & &1.id) == [memory.id]
    end

    test "a candidate with no verdict behind it reaches nobody" do
      author = account("on-candidate")
      reader = account("on-candidate-reader")

      {:ok, memory} = Memories.create(author, candidate())
      assert Admissions.status(memory) == "candidate"

      assert %Recall{memories: []} = Memories.recall(reader, @turn)
    end

    test "nor does a row that claims admission for itself" do
      author = account("on-self-claimed")
      reader = account("on-self-claimed-reader")

      {:ok, memory} = Memories.create(author, candidate(%{"admission" => "admitted"}))

      assert memory.admission == "admitted"
      assert Admissions.status(memory) == "candidate"
      assert %Recall{memories: []} = Memories.recall(reader, @turn)
    end

    test "a rejected memory reaches nobody" do
      author = account("on-rejected")
      reader = account("on-rejected-reader")

      {:ok, memory} = Memories.create(author, candidate())

      {:ok, _record} =
        Admissions.record(steward(), memory.id, %{
          "verdict" => "rejected",
          "ground" => "The receipt does not say this."
        })

      assert Admissions.status(memory) == "rejected"
      assert %Recall{memories: []} = Memories.recall(reader, @turn)
    end

    test "a suspended memory leaves recall until the challenge is resolved" do
      author = account("on-suspended")
      reader = account("on-suspended-reader")
      challenger = account("on-suspended-challenger")

      memory = admitted(author)

      {:ok, challenge} =
        Admissions.challenge(challenger, memory.id, %{
          "ground" => "The gateway returns 402 for an expired credential too.",
          "evidence_refs" => [
            %{"kind" => "url", "ref" => "https://example.test/status", "digest" => "sha256:1c2d"}
          ]
        })

      assert Admissions.status(memory) == "suspended"
      assert %Recall{memories: []} = Memories.recall(reader, @turn)

      {:ok, _refutation} =
        Admissions.refute(steward(), challenge.id, %{
          "ground" => "The receipt distinguishes the two cases."
        })

      assert Admissions.status(memory) == "admitted"
      %Recall{memories: restored} = Memories.recall(reader, @turn)
      assert Enum.map(restored, & &1.id) == [memory.id]
    end

    test "a superseded memory reaches nobody; its replacement does" do
      author = account("on-superseded")
      reader = account("on-superseded-reader")

      memory = admitted(author)

      {:ok, replacement} =
        Admissions.supersede(
          author,
          memory.id,
          candidate(%{"body" => "A 402 means the credential expired. Check the key first."})
        )

      {:ok, _record} =
        Admissions.record(steward(), replacement.id, %{
          "verdict" => "admitted",
          "ground" => "The corrected claim is supported."
        })

      %Recall{memories: recalled} = Memories.recall(reader, @turn)

      assert Enum.map(recalled, & &1.id) == [replacement.id]
    end

    # The tier floor is enforced in three places and reachable through none of
    # them. `dark` and `pulse` are refused by the changeset, refused by
    # `memories_system_shape` when a caller writes around it, and named as a
    # predicate in the eligibility read so the floor does not depend on the
    # table alone.
    test "a sub-ledger tier cannot be written, and the read names the floor anyway" do
      author = account("on-dark-tier")

      assert {:error, changeset} = Memories.create(author, candidate(%{"tier" => "dark"}))
      assert %{tier: ["is invalid"]} = errors_on(changeset)

      assert_raise Ecto.ConstraintError, ~r/memories_system_shape/, fn ->
        around_the_changeset(author, %{tier: "pulse"})
      end

      assert SystemRecall.tiers() == ~w(ledger glass)
    end

    test "an empty store recalls nothing rather than failing the turn" do
      reader = account("on-empty")

      assert %Recall{memories: [], dropped: 0} = Memories.recall(reader, @turn)
    end
  end

  describe "the note" do
    setup do
      surfacing(true)
      :ok
    end

    test "names the bucket, the claim date, and the derived status" do
      author = account("note-author")
      reader = account("note-reader")

      _memory =
        admitted(author, %{"body" => "Check gateway status first.", "as_of" => ~D[2026-08-25]})

      note = reader |> Memories.recall(@turn) |> Note.render()

      assert note ==
               "[From memory: (system, as of 2026-08-25, admitted)] Check gateway status first."
    end

    test "reads differently from the account's own memories in the same note" do
      reader = account("note-mixed")
      author = account("note-mixed-author")

      {:ok, _asked} = Memories.create(reader, %{"body" => "I use pnpm, not npm."})
      _memory = admitted(author, %{"body" => "Check gateway status first."})

      note = reader |> Memories.recall(@turn) |> Note.render()

      assert [own, network] = String.split(note, "\n")
      assert own =~ ~r/^\[From memory: user, /

      assert network ==
               "[From memory: (system, as of 2026-08-25, admitted)] Check gateway status first."
    end

    test "prints the status the records derived rather than the column the author wrote" do
      author = account("note-derived")
      reader = account("note-derived-reader")

      _memory =
        admitted(author, %{"admission" => "rejected", "body" => "Check gateway status first."})

      note = reader |> Memories.recall(@turn) |> Note.render()

      assert note =~ "admitted)"
      refute note =~ "rejected"
    end

    test "spends the account's character budget rather than one of its own" do
      reader = account("note-budget")
      author = account("note-budget-author")

      {:ok, _asked} = Memories.create(reader, %{"body" => String.duplicate("a", 60)})
      _memory = admitted(author, %{"body" => String.duplicate("b", 60)})

      %Recall{memories: recalled} =
        Memories.recall(reader, @turn, maximum_attached_characters: 80)

      assert length(recalled) == 1
      assert hd(recalled).bucket == "user"
    end
  end

  describe "the caps" do
    setup do
      surfacing(true)
      :ok
    end

    test "hold the pool to a quarter of its slots per account" do
      prolific = account("cap-prolific")
      other = account("cap-other")

      for index <- 1..8 do
        admitted(prolific, %{
          "slug" => "sys:prolific-#{index}",
          "body" => "Gateway claim number #{index} about the inference gateway."
        })
      end

      only = admitted(other, %{"slug" => "sys:other-1", "body" => "One claim about the gateway."})

      pool = SystemRecall.pool(@turn)

      # Nine eligible rows, so the cap is three per account, rounded up.
      assert SystemRecall.pool_cap(9) == 3
      assert Enum.count(pool, &(&1.user_id == prolific.id)) == 3
      assert only.id in Enum.map(pool, & &1.id)
    end

    test "hold a note to one memory per account and two in all" do
      prolific = account("note-cap-prolific")
      second = account("note-cap-second")
      third = account("note-cap-third")
      reader = account("note-cap-reader")

      for index <- 1..4 do
        admitted(prolific, %{
          "slug" => "sys:note-prolific-#{index}",
          "body" => "Gateway claim number #{index} about the inference gateway."
        })
      end

      admitted(second, %{
        "slug" => "sys:note-second",
        "body" => "A second account's gateway claim."
      })

      admitted(third, %{"slug" => "sys:note-third", "body" => "A third account's gateway claim."})

      %Recall{memories: recalled} = Memories.recall(reader, @turn)

      assert length(recalled) == 2

      authors = Enum.map(recalled, & &1.user_id)
      assert authors == Enum.uniq(authors)
      assert Enum.count(recalled, &(&1.user_id == prolific.id)) <= 1
    end

    test "leave a single-account store recallable rather than empty" do
      author = account("cap-single")
      reader = account("cap-single-reader")

      for index <- 1..4 do
        admitted(author, %{
          "slug" => "sys:single-#{index}",
          "body" => "Gateway claim number #{index} about the inference gateway."
        })
      end

      %Recall{memories: recalled} = Memories.recall(reader, @turn)

      assert length(recalled) == 1
    end

    test "do not report what they excluded" do
      prolific = account("cap-silent")
      reader = account("cap-silent-reader")

      for index <- 1..4 do
        admitted(prolific, %{
          "slug" => "sys:silent-#{index}",
          "body" => "Gateway claim number #{index} about the inference gateway."
        })
      end

      %Recall{dropped: dropped} = Memories.recall(reader, @turn)

      assert dropped == 0
    end

    test "round up so a pool of one is not emptied by its own cap" do
      assert SystemRecall.pool_cap(0) == 0
      assert SystemRecall.pool_cap(1) == 1
      assert SystemRecall.pool_cap(4) == 1
      assert SystemRecall.pool_cap(5) == 2
      assert SystemRecall.pool_cap(8) == 2
    end
  end

  describe "determinism" do
    setup do
      surfacing(true)
      :ok
    end

    test "equal inputs give equal pools and equal notes" do
      first = account("det-first")
      second = account("det-second")
      reader = account("det-reader")

      for index <- 1..3 do
        admitted(first, %{
          "slug" => "sys:det-first-#{index}",
          "body" => "First account's gateway claim number #{index}."
        })

        admitted(second, %{
          "slug" => "sys:det-second-#{index}",
          "body" => "Second account's gateway claim number #{index}."
        })
      end

      pools = for _repeat <- 1..5, do: Enum.map(SystemRecall.pool(@turn), & &1.id)
      notes = for _repeat <- 1..5, do: reader |> Memories.recall(@turn) |> Note.render()

      assert Enum.uniq(pools) == [hd(pools)]
      assert Enum.uniq(notes) == [hd(notes)]
    end
  end

  # MEMORY-004 and MEMORY-001's amendment. The eligibility filter is what
  # replaces the scope predicate for this bucket, so it has to be a predicate:
  # written into the query, not applied to what the query returned.
  describe "MEMORY-004" do
    @source "lib/openagents/memories/system_recall.ex"

    test "the eligibility filter is written into the query" do
      query = @source |> queries() |> List.first()

      assert query, "no query rooted at `Memory` found in #{@source}"

      for predicate <- ~w(bucket superseded_by_id tier id)a do
        assert names?(query, predicate),
               """
               The eligibility read in #{@source} does not name `#{predicate}`.
               MEMORY-001's amendment replaces the account predicate with this
               filter, so every part of it belongs in the query.

               #{Macro.to_string(query)}
               """
      end
    end

    test "and it names no account" do
      for query <- queries(@source) do
        refute names?(query, :user_id),
               """
               A query in #{@source} names `user_id`. This module holds the
               reads that deliberately do not; an account-scoped read belongs
               in `OpenAgents.Memories`.
               """
      end
    end

    defp queries(path) do
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalker()
      |> Enum.filter(fn
        {:from, _meta, [{:in, _, [_binding, {:__aliases__, _, [:Memory]}]} | _]} -> true
        _other -> false
      end)
    end

    defp names?(query, field) do
      query
      |> Macro.prewalker()
      |> Enum.any?(fn
        {{:., _, [_, ^field]}, _, _} -> true
        _other -> false
      end)
    end
  end

  # The bucket still belongs to the account that wrote it for every purpose but
  # recall. Reading a network claim in a turn does not make it listable,
  # fetchable, or correctable by the reader.
  describe "the write boundary is unmoved" do
    setup do
      surfacing(true)
      :ok
    end

    test "a reader who recalls a system memory still cannot read it through the store" do
      author = account("boundary-author")
      reader = account("boundary-reader")

      memory = admitted(author)

      %Recall{memories: recalled} = Memories.recall(reader, @turn)
      assert Enum.map(recalled, & &1.id) == [memory.id]

      assert {:error, :not_found} = Memories.fetch(reader, memory.id)
      assert Memories.list(reader, bucket: "system") == []
      assert {:error, :not_supersedable} = Admissions.supersede(reader, memory.id, candidate())
    end

    test "and the account's own buckets stay account-scoped with the flag on" do
      reader = account("boundary-scoped")
      other = account("boundary-scoped-other")

      {:ok, _theirs} = Memories.create(other, %{"body" => "Deploy with yarn."})

      assert %Recall{memories: []} = Memories.recall(reader, "deploy with yarn")
    end
  end
end
