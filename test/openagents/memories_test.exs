defmodule OpenAgents.MemoriesTest do
  @moduledoc """
  The cloud memory store: what it writes, what it hands back, and what it
  refuses.

  The two properties worth the most attention are the ones a later change is
  most likely to break quietly. A superseded memory must leave recall the
  moment it is corrected, or a reader who fixed a wrong preference keeps being
  answered from the wrong one. And the account boundary must be a predicate
  in the query rather than a filter someone applied afterwards (MEMORY-010),
  because the second kind holds right up until a caller assembles a candidate
  list wrongly.
  """
  # Not async: the ceiling test narrows `:memory_recall`, which is application
  # environment and therefore shared with every test running beside it.
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Memories
  alias OpenAgents.Memories.{Memory, Recall}

  # Merge over the configured recall settings and put them back afterwards.
  # Deleting the key instead would leave every later reader without the
  # `config/config.exs` values, which is a different and much wider change than
  # the one a test meant to make.
  defp narrow(overrides) do
    previous = Application.get_env(:openagents, :memory_recall) || []
    Application.put_env(:openagents, :memory_recall, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:openagents, :memory_recall, previous) end)
  end

  defp account(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()
    login = "memories-" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 12))

    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  describe "create/2" do
    test "writes a user-bucket memory owned by the account" do
      user = account("create-user")

      assert {:ok, memory} = Memories.create(user, %{"body" => "I use pnpm, not npm."})

      assert memory.user_id == user.id
      assert memory.bucket == "user"
      assert memory.body == "I use pnpm, not npm."
      assert memory.superseded_by_id == nil
    end

    test "writes a learned memory with the work that taught it" do
      user = account("create-learned")

      assert {:ok, memory} =
               Memories.create(user, %{
                 "body" => "The suite needs a database before it will boot.",
                 "bucket" => "learned",
                 "source_ref" => "thread:0e2f"
               })

      assert memory.bucket == "learned"
      assert memory.source_ref == "thread:0e2f"
    end

    # The owner is set on the struct, never cast, so a request body naming
    # somebody else's account changes nothing.
    test "refuses to take the owner from the attributes" do
      user = account("create-owner")
      other = account("create-owner-other")

      assert {:ok, memory} =
               Memories.create(user, %{"body" => "Mine.", "user_id" => other.id})

      assert memory.user_id == user.id
    end

    test "refuses an empty body and an unknown bucket" do
      user = account("create-invalid")

      assert {:error, changeset} = Memories.create(user, %{"body" => "   "})
      assert %{body: _} = errors_on(changeset)

      assert {:error, changeset} =
               Memories.create(user, %{"body" => "Fine.", "bucket" => "wishlist"})

      assert %{bucket: _} = errors_on(changeset)
    end

    # `system` is in the vocabulary and carries a shape of its own
    # (`OpenAgents.Memories.SystemMemoryTest`). A write that names the bucket
    # and none of its fields is refused for the fields, not for the bucket.
    test "refuses a system memory that carries none of the system fields" do
      user = account("create-system-bare")

      assert {:error, changeset} =
               Memories.create(user, %{"body" => "Fine.", "bucket" => "system"})

      errors = errors_on(changeset)

      assert Map.has_key?(errors, :evidence_refs)
      assert Map.has_key?(errors, :tier)
      refute Map.has_key?(errors, :bucket)
    end

    test "refuses a body longer than the store's bound" do
      user = account("create-long")
      body = String.duplicate("x", Memory.body_characters() + 1)

      assert {:error, changeset} = Memories.create(user, %{"body" => body})
      assert %{body: _} = errors_on(changeset)
    end

    test "refuses a write past the account's ceiling" do
      user = account("create-quota")
      narrow(maximum_live_memories: 2)

      assert {:ok, _first} = Memories.create(user, %{"body" => "One."})
      assert {:ok, second} = Memories.create(user, %{"body" => "Two."})
      assert {:error, :quota_reached} = Memories.create(user, %{"body" => "Three."})

      # A correction is admitted at the ceiling: it replaces a live row with a
      # live row, so an account that filled its store can still fix it.
      assert {:ok, _corrected} =
               Memories.create(user, %{"body" => "Two, corrected.", "supersedes" => second.id})
    end
  end

  describe "supersession" do
    test "a correction points the old memory at the new one and leaves recall" do
      user = account("supersede")

      {:ok, wrong} = Memories.create(user, %{"body" => "I use npm."})

      {:ok, right} =
        Memories.create(user, %{"body" => "I use pnpm, not npm.", "supersedes" => wrong.id})

      assert Repo.get!(Memory, wrong.id).superseded_by_id == right.id

      live = Memories.list(user)
      assert Enum.map(live, & &1.id) == [right.id]

      both = Memories.list(user, include_superseded: true)
      assert length(both) == 2
    end

    test "a superseded memory is never recalled" do
      user = account("supersede-recall")

      {:ok, wrong} = Memories.create(user, %{"body" => "Deploy with the yarn command."})

      {:ok, _right} =
        Memories.create(user, %{
          "body" => "Deploy with the pnpm command.",
          "supersedes" => wrong.id
        })

      %Recall{memories: recalled} = Memories.recall(user, "deploy the project")

      assert Enum.map(recalled, & &1.body) == ["Deploy with the pnpm command."]
    end

    test "refuses to supersede a memory of another account" do
      user = account("supersede-scope")
      other = account("supersede-scope-other")

      {:ok, theirs} = Memories.create(other, %{"body" => "Theirs."})

      assert {:error, :supersedes_not_found} =
               Memories.create(user, %{"body" => "Mine.", "supersedes" => theirs.id})
    end

    test "refuses to supersede an already superseded memory" do
      user = account("supersede-twice")

      {:ok, first} = Memories.create(user, %{"body" => "First."})
      {:ok, _second} = Memories.create(user, %{"body" => "Second.", "supersedes" => first.id})

      assert {:error, :supersedes_not_found} =
               Memories.create(user, %{"body" => "Third.", "supersedes" => first.id})
    end
  end

  describe "list/2 and delete/2" do
    test "lists one account's memories and never another's" do
      user = account("list-scope")
      other = account("list-scope-other")

      {:ok, mine} = Memories.create(user, %{"body" => "Mine."})
      {:ok, _theirs} = Memories.create(other, %{"body" => "Theirs."})

      assert Enum.map(Memories.list(user), & &1.id) == [mine.id]
    end

    test "narrows to one bucket" do
      user = account("list-bucket")

      {:ok, _explicit} = Memories.create(user, %{"body" => "Explicit."})
      {:ok, learned} = Memories.create(user, %{"body" => "Learned.", "bucket" => "learned"})

      assert Enum.map(Memories.list(user, bucket: "learned"), & &1.id) == [learned.id]
    end

    test "removes a memory outright, and refuses another account's" do
      user = account("delete")
      other = account("delete-other")

      {:ok, mine} = Memories.create(user, %{"body" => "Mine."})

      assert {:error, :not_found} = Memories.delete(other, mine.id)
      assert {:ok, _deleted} = Memories.delete(user, mine.id)
      assert Memories.list(user) == []
      assert {:error, :not_found} = Memories.delete(user, mine.id)
    end

    test "an unreadable id is not found rather than an error" do
      user = account("delete-unreadable")

      assert {:error, :not_found} = Memories.delete(user, "not-a-uuid")
    end
  end

  describe "recall/3" do
    test "attaches a user memory that shares no word with the turn" do
      user = account("recall-user-bucket")

      {:ok, _memory} = Memories.create(user, %{"body" => "I use pnpm, not npm."})

      %Recall{memories: recalled} = Memories.recall(user, "install the deps")

      assert Enum.map(recalled, & &1.body) == ["I use pnpm, not npm."]
    end

    # The other half of the same rule: a learned memory has to be about the
    # turn before it interrupts it, so an unrelated one stays out.
    test "leaves an unrelated learned memory out" do
      user = account("recall-learned-floor")

      {:ok, _related} =
        Memories.create(user, %{
          "body" => "The migration must run before the suite boots.",
          "bucket" => "learned"
        })

      {:ok, _unrelated} =
        Memories.create(user, %{
          "body" => "Screenshots belong in the artifacts directory.",
          "bucket" => "learned"
        })

      %Recall{memories: recalled} = Memories.recall(user, "the migration failed")

      assert Enum.map(recalled, & &1.body) == [
               "The migration must run before the suite boots."
             ]
    end

    test "recalls nothing for an account with no memories" do
      user = account("recall-empty")

      assert %Recall{memories: [], dropped: 0} = Memories.recall(user, "anything at all")
    end

    test "recalls nothing for an empty turn rather than everything" do
      user = account("recall-empty-query")

      {:ok, _memory} = Memories.create(user, %{"body" => "Something."})

      assert %Recall{memories: []} = Memories.recall(user, "")
    end

    test "never reaches another account's memories" do
      user = account("recall-scope")
      other = account("recall-scope-other")

      {:ok, _theirs} = Memories.create(other, %{"body" => "Deploy with yarn."})

      assert %Recall{memories: []} = Memories.recall(user, "deploy with yarn")
    end

    test "bounds the count and reports what it dropped" do
      user = account("recall-count-bound")

      for index <- 1..6 do
        {:ok, _memory} = Memories.create(user, %{"body" => "Preference number #{index}."})
      end

      %Recall{memories: recalled, dropped: dropped} =
        Memories.recall(user, "what do you know", maximum_attached: 2)

      assert length(recalled) == 2
      assert dropped == 4
    end

    test "bounds the characters and reports what it dropped" do
      user = account("recall-size-bound")

      for index <- 1..4 do
        {:ok, _memory} =
          Memories.create(user, %{"body" => String.duplicate("#{index}", 40)})
      end

      %Recall{memories: recalled, dropped: dropped} =
        Memories.recall(user, "what do you know", maximum_attached_characters: 100)

      assert length(recalled) == 2
      assert dropped == 2
    end
  end

  # MEMORY-010. The account boundary is written into the queries, not applied
  # to their results. This reads each module's own source AST the way
  # `OpenAgents.Memory.ScopeBoundaryTest` does, so a query added beside the
  # scoped ones fails here whether or not anyone remembered it exists.
  describe "MEMORY-010" do
    @scoped_modules [
      "lib/openagents/memories.ex",
      "lib/openagents/memories/retrieval/lexical.ex",
      # The system bucket's write authority reaches one row of another account
      # — a steward correcting a network claim — and it does so as a predicate
      # inside the `UPDATE`, naming `user_id` beside the role. Nothing is read
      # out, so a caller with no standing learns nothing from the refusal.
      "lib/openagents/memories/admissions.ex",
      # The system bucket's read path, which names no account at all.
      "lib/openagents/memories/system_recall.ex"
    ]

    # MEMORY-001's amendment, written as a budget. Two queries in the plane
    # name no account — the system bucket's eligibility read and its shared
    # ranking query — and each of them must name the `system` bucket in place
    # of `user_id`. Declaring the count by module is what makes a third
    # unscoped query fail here: it is admitted by name and by number, never by
    # shape, so nothing widens by resembling something that already did.
    @unscoped_queries %{
      "lib/openagents/memories/retrieval/lexical.ex" => 1,
      "lib/openagents/memories/system_recall.ex" => 1
    }

    test "every query rooted at the memory plane names user_id, or the system bucket" do
      for path <- @scoped_modules, query <- memory_queries(path) do
        assert names_user_id?(query) or names_system_bucket?(query),
               """
               A query in #{path} is rooted at `Memory` and names neither
               `user_id` nor the `system` bucket. MEMORY-010 requires the
               account boundary to be a database predicate, and MEMORY-001's
               amendment admits exactly one substitute for it. Add the column,
               or amend the invariant.

               #{Macro.to_string(query)}
               """
      end
    end

    test "and no more queries name no account than the amendment declares" do
      for path <- @scoped_modules do
        declared = Map.get(@unscoped_queries, path, 0)

        found =
          path
          |> memory_queries()
          |> Enum.count(&(not names_user_id?(&1)))

        assert found == declared,
               """
               #{path} has #{found} query or queries rooted at `Memory` that
               name no account, and MEMORY-001's amendment declares #{declared}.
               Every one of them reads across the account boundary. Declare it
               here on purpose, and amend MEMORY-001 to say why, or scope it.
               """
      end
    end

    test "the enumeration actually finds queries" do
      found = Enum.flat_map(@scoped_modules, &memory_queries/1)
      assert length(found) >= 4
    end

    defp memory_queries(path) do
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalker()
      |> Enum.filter(&rooted_at_memory?/1)
    end

    # An Ecto query rooted at the schema: `from(memory in Memory, …)`.
    defp rooted_at_memory?(
           {:from, _meta, [{:in, _, [_binding, {:__aliases__, _, [:Memory]}]} | _]}
         ),
         do: true

    # A repo call taking the schema directly: `Repo.get_by(Memory, …)`. Without
    # this clause the enumeration would pass a `get_by` that dropped the
    # account, which is the same hole in a different shape.
    defp rooted_at_memory?(
           {{:., _, [{:__aliases__, _, [:Repo]}, _function]}, _meta,
            [{:__aliases__, _, [:Memory]} | _rest]}
         ),
         do: true

    defp rooted_at_memory?(_node), do: false

    # `memory.bucket == "system"` in a query. The literal is required: a query
    # comparing `bucket` to a bound variable could be handed any bucket at all,
    # which is the account boundary back where it started.
    defp names_system_bucket?(query) do
      query
      |> Macro.prewalker()
      |> Enum.any?(fn
        {:==, _, [{{:., _, [_, :bucket]}, _, _}, "system"]} -> true
        _other -> false
      end)
    end

    # `memory.user_id` in a query, or `user_id:` in a repo call's clauses.
    defp names_user_id?(query) do
      query
      |> Macro.prewalker()
      |> Enum.any?(fn
        {{:., _, [_, :user_id]}, _, _} -> true
        {:user_id, _value} -> true
        _other -> false
      end)
    end
  end
end
