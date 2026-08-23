defmodule OpenAgents.StacksTest do
  use OpenAgents.DataCase

  alias OpenAgents.PullRequests
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.Stack
  alias OpenAgents.Stacks.StackEntry

  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  defp sha(character), do: String.duplicate(character, 40)

  defp pull_request(repository, head_ref, base_ref, attrs \\ %{}) do
    issue = issue_fixture(repository, %{title: "PR #{head_ref}"})

    defaults = %{
      repository_id: repository.id,
      issue_id: issue.id,
      head_repository_id: repository.id,
      head_ref: head_ref,
      head_sha: sha_for(head_ref),
      base_ref: base_ref,
      base_sha: sha_for(base_ref),
      state: "open"
    }

    {:ok, pull_request} =
      %PullRequest{}
      |> PullRequest.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    pull_request
  end

  defp sha_for(ref) do
    :sha
    |> :crypto.hash(ref)
    |> Base.encode16(case: :lower)
  end

  defp chain(repository, refs) do
    refs
    |> Enum.zip(["main" | refs])
    |> Enum.map(fn {head, base} -> pull_request(repository, head, base) end)
  end

  describe "create/3" do
    test "creates a stack with contiguous entries and stored boundaries" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom, middle, top] = chain(repository, ["layer-1", "layer-2", "layer-3"])

      assert {:ok, %Stack{} = stack} = Stacks.create(repository, [bottom, middle, top], user)
      assert stack.number == 1
      assert stack.trunk_ref == "main"
      assert stack.state == "open"
      assert stack.health == "healthy"
      assert stack.version == 1

      [entry_1, entry_2, entry_3] = stack.entries
      assert Enum.map(stack.entries, & &1.position) == [1, 2, 3]
      assert entry_1.boundary_oid == bottom.base_sha
      assert entry_2.boundary_oid == bottom.head_sha
      assert entry_3.boundary_oid == middle.head_sha
      assert entry_1.observed_head_oid == bottom.head_sha
      assert entry_2.observed_head_oid == middle.head_sha
      assert entry_3.observed_head_oid == top.head_sha
    end

    test "numbers are repository-local" do
      user = repository_user_fixture("stack-author")
      first_repository = repository_fixture()
      second_repository = repository_fixture()

      [first_bottom] = chain(first_repository, ["layer-1"])
      [second_bottom] = chain(second_repository, ["layer-1"])

      assert {:ok, %Stack{number: 1}} = Stacks.create(first_repository, [first_bottom], user)
      assert {:ok, %Stack{number: 1}} = Stacks.create(second_repository, [second_bottom], user)

      [next] = chain(first_repository, ["layer-2b"])
      next = %{next | base_ref: "main", base_sha: sha_for("main")}
      assert {:ok, %Stack{number: 2}} = Stacks.create(first_repository, [next], user)
    end

    test "rejects a stack above the maximum size" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()

      refs = Enum.map(1..(Stacks.max_entries() + 1), &"layer-#{&1}")
      pull_requests = chain(repository, refs)

      assert {:error, :stack_too_large} = Stacks.create(repository, pull_requests, user)
    end

    test "rejects an empty stack" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()

      assert {:error, :empty_stack} = Stacks.create(repository, [], user)
    end

    test "rejects pull requests from another repository" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      other_repository = repository_fixture()
      [foreign] = chain(other_repository, ["layer-1"])

      assert {:error, :repository_mismatch} = Stacks.create(repository, [foreign], user)
    end

    test "rejects cross-repository heads" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      fork = repository_fixture()

      forked =
        pull_request(repository, "layer-1", "main", %{head_repository_id: fork.id})

      assert {:error, :cross_repository_head} = Stacks.create(repository, [forked], user)
    end

    test "rejects closed pull requests" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      closed = pull_request(repository, "layer-1", "main", %{state: "closed"})

      assert {:error, :pull_request_not_open} = Stacks.create(repository, [closed], user)
    end

    test "rejects duplicate pull requests" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom] = chain(repository, ["layer-1"])

      assert {:error, :duplicate_pull_request} =
               Stacks.create(repository, [bottom, bottom], user)
    end

    test "rejects duplicate branches" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      bottom = pull_request(repository, "layer-1", "main")
      loop = pull_request(repository, "main", "layer-1")

      assert {:error, :duplicate_branch} = Stacks.create(repository, [bottom, loop], user)
    end

    test "rejects a broken direct-base chain" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      bottom = pull_request(repository, "layer-1", "main")
      detached = pull_request(repository, "layer-2", "main")

      assert {:error, :broken_base_chain} = Stacks.create(repository, [bottom, detached], user)
    end

    test "rejects a pull request that is already in an active stack" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom] = chain(repository, ["layer-1"])

      assert {:ok, _stack} = Stacks.create(repository, [bottom], user)
      assert {:error, :already_stacked} = Stacks.create(repository, [bottom], user)
    end
  end

  describe "entry constraints" do
    test "one pull request belongs to at most one active stack" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom] = chain(repository, ["layer-1"])
      other = pull_request(repository, "layer-x", "main")

      assert {:ok, stack} = Stacks.create(repository, [bottom], user)
      assert {:ok, other_stack} = Stacks.create(repository, [other], user)

      assert {:error, changeset} =
               %StackEntry{}
               |> StackEntry.changeset(%{
                 stack_id: other_stack.id,
                 pull_request_id: bottom.id,
                 position: 2,
                 boundary_oid: sha("a"),
                 observed_head_oid: sha("b")
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).pull_request_id

      [entry] = stack.entries
      removed_at = DateTime.utc_now()
      {:ok, _removed} = entry |> StackEntry.changeset(%{removed_at: removed_at}) |> Repo.update()

      assert {:ok, _entry} =
               %StackEntry{}
               |> StackEntry.changeset(%{
                 stack_id: other_stack.id,
                 pull_request_id: bottom.id,
                 position: 2,
                 boundary_oid: sha("a"),
                 observed_head_oid: sha("b")
               })
               |> Repo.insert()
    end

    test "active positions are unique per stack" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom] = chain(repository, ["layer-1"])
      other = pull_request(repository, "layer-x", "main")

      assert {:ok, stack} = Stacks.create(repository, [bottom], user)

      assert {:error, changeset} =
               %StackEntry{}
               |> StackEntry.changeset(%{
                 stack_id: stack.id,
                 pull_request_id: other.id,
                 position: 1,
                 boundary_oid: sha("a"),
                 observed_head_oid: sha("b")
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).stack_id
    end

    test "positions start at one" do
      changeset =
        StackEntry.changeset(%StackEntry{}, %{
          stack_id: Ecto.UUID.generate(),
          pull_request_id: Ecto.UUID.generate(),
          position: 0,
          boundary_oid: sha("a"),
          observed_head_oid: sha("b")
        })

      assert "must be greater than or equal to 1" in errors_on(changeset).position
    end

    test "OIDs accept SHA-1 and SHA-256 object names and reject other values" do
      base = %{
        stack_id: Ecto.UUID.generate(),
        pull_request_id: Ecto.UUID.generate(),
        position: 1,
        observed_head_oid: sha("b")
      }

      sha256 = String.duplicate("ab", 32)

      changeset = StackEntry.changeset(%StackEntry{}, Map.put(base, :boundary_oid, sha256))
      assert Ecto.Changeset.get_field(changeset, :boundary_oid) == sha256

      for invalid <- [String.duplicate("a", 39), String.duplicate("z", 40), 42] do
        changeset = StackEntry.changeset(%StackEntry{}, Map.put(base, :boundary_oid, invalid))
        assert "is invalid" in errors_on(changeset).boundary_oid
      end
    end

    test "OIDs round-trip through the database" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom] = chain(repository, ["layer-1"])

      assert {:ok, stack} = Stacks.create(repository, [bottom], user)
      [entry] = stack.entries
      reloaded = Repo.get!(StackEntry, entry.id)

      assert reloaded.boundary_oid == bottom.base_sha
      assert reloaded.observed_head_oid == bottom.head_sha
    end
  end

  describe "base edits" do
    test "generic base edits fail while a pull request is stacked" do
      user = repository_user_fixture("stack-author")
      repository = repository_with_member_fixture(user)
      [bottom] = chain(repository, ["layer-1"])

      assert :ok = Stacks.ensure_base_editable(bottom)
      assert {:ok, _stack} = Stacks.create(repository, [bottom], user)
      assert {:error, :stack_managed_base} = Stacks.ensure_base_editable(bottom)

      assert {:error, :stack_managed_base} =
               PullRequests.update(bottom, %{"base" => "other-branch"}, user)
    end
  end

  describe "health and state" do
    test "a stale graph never dissolves a stack" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom] = chain(repository, ["layer-1"])

      assert {:ok, stack} = Stacks.create(repository, [bottom], user)
      assert {:ok, updated} = Stacks.set_health(stack, "needs_rebase")
      assert updated.health == "needs_rebase"
      assert updated.state == "open"
      assert updated.version == stack.version
    end

    test "rejects unknown health states" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom] = chain(repository, ["layer-1"])

      assert {:ok, stack} = Stacks.create(repository, [bottom], user)
      assert {:error, changeset} = Stacks.set_health(stack, "broken")
      assert "is invalid" in errors_on(changeset).health
    end

    test "completing and dissolving bump the version and require the caller's version" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      [bottom] = chain(repository, ["layer-1"])
      other = pull_request(repository, "layer-x", "main")

      assert {:ok, stack} = Stacks.create(repository, [bottom], user)
      assert {:ok, completed} = Stacks.complete(stack)
      assert completed.state == "completed"
      assert completed.version == stack.version + 1

      assert {:error, :stale_stack_version} = Stacks.complete(stack)
      assert {:error, :stack_not_open} = Stacks.dissolve(completed)

      assert {:ok, second} = Stacks.create(repository, [other], user)
      assert {:ok, dissolved} = Stacks.dissolve(second)
      assert dissolved.state == "dissolved"
      assert dissolved.version == second.version + 1
    end

    test "get_by_number!/2 returns ordered active entries" do
      user = repository_user_fixture("stack-author")
      repository = repository_fixture()
      pull_requests = chain(repository, ["layer-1", "layer-2"])

      assert {:ok, stack} = Stacks.create(repository, pull_requests, user)
      loaded = Stacks.get_by_number!(repository, stack.number)

      assert Enum.map(loaded.entries, & &1.position) == [1, 2]
      assert Enum.map(loaded.entries, & &1.pull_request.id) == Enum.map(pull_requests, & &1.id)
    end
  end
end
