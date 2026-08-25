defmodule OpenAgents.Threads.VisibilityTest do
  @moduledoc """
  THREAD-002: a thread's transcript is private until its owner says otherwise.

  The tier vocabulary is not this module's invention — it is the
  `dark/pulse/ledger/glass` ladder `OpenAgents.Transparency` and
  `OpenAgents.Forge.Visibility` already use (`docs/taxonomy.md`), and the first
  test here holds the thread's admitted set to it, so a fifth word cannot enter
  through this door.
  """
  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.DataRights.AccountExport
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Thread
  alias OpenAgents.Transparency

  import OpenAgents.IssuesFixtures

  defp owner(key), do: github_user("thread-visibility-#{key}")

  defp event_types(thread) do
    thread |> Threads.list_events() |> Enum.map(& &1.event_type)
  end

  describe "the vocabulary" do
    test "a thread's tiers are rungs of the shared transparency ladder" do
      shared = Enum.map(Transparency.tier_atoms(), &Atom.to_string/1)

      assert Thread.visibilities() -- shared == [],
             "a thread must not invent a tier word the transparency ladder does not have"

      assert Thread.default_visibility() == "dark"
      assert Thread.wide_visibilities() == ["ledger"]
    end

    test "the tiers with no thread read path behind them are not offered" do
      refute "pulse" in Thread.visibilities()
      refute "glass" in Thread.visibilities()
    end
  end

  describe "open/3" do
    test "a thread defaults to owner-only" do
      {:ok, thread} = Threads.open(owner("default"), "Keep it to myself")

      assert thread.visibility == "dark"
      refute Thread.wide?(thread)
    end

    test "an explicit tier is accepted and recorded as an act" do
      {:ok, thread} =
        Threads.open(owner("explicit"), "Share the transcript", visibility: "ledger")

      assert thread.visibility == "ledger"
      assert Thread.wide?(thread)

      # Widening leaves a record in the transcript, not only a column value.
      assert event_types(thread) == ["thread.opened", "thread.visibility_set"]
      assert thread.event_count == 2

      widened = thread |> Threads.list_events() |> List.last()
      assert widened.payload == %{"visibility" => "ledger", "from" => "dark"}
    end

    test "a default thread records no widening" do
      {:ok, thread} = Threads.open(owner("unwidened"), "Nothing to declare")

      assert event_types(thread) == ["thread.opened"]
      assert thread.event_count == 1
    end

    test "an unknown tier is refused, and nothing is opened" do
      user = owner("unknown")

      assert {:error, changeset} = Threads.open(user, "Widen me", visibility: "public")
      assert "is invalid" in errors_on(changeset).visibility

      assert Threads.list_for_user(user) == []
    end

    test "a tier the surface cannot enforce is refused like any other" do
      for tier <- ~w(pulse glass) do
        assert {:error, changeset} =
                 Threads.open(owner("unenforceable"), "Widen me", visibility: tier)

        assert "is invalid" in errors_on(changeset).visibility
      end
    end
  end

  describe "fetch_readable/2" do
    test "the owner reads their own thread at either tier" do
      user = owner("owner-reads")

      {:ok, dark} = Threads.open(user, "Private work")
      {:ok, wide} = Threads.open(user, "Shared work", visibility: "ledger")

      assert {:ok, %Thread{id: id}, :owner} = Threads.fetch_readable(user, dark.id)
      assert id == dark.id
      assert {:ok, %Thread{}, :owner} = Threads.fetch_readable(user, wide.id)
    end

    test "a stranger reads a wide thread and is named a reader, not an owner" do
      {:ok, thread} = Threads.open(owner("wide"), "Shared work", visibility: "ledger")

      assert {:ok, %Thread{id: id}, :reader} =
               Threads.fetch_readable(owner("stranger-wide"), thread.id)

      assert id == thread.id
    end

    test "a stranger cannot read an owner-only thread" do
      {:ok, thread} = Threads.open(owner("dark"), "Private work")

      assert Threads.fetch_readable(owner("stranger-dark"), thread.id) == :error
    end

    test "an unknown id is the same refusal as somebody else's private thread" do
      assert Threads.fetch_readable(owner("missing"), Ecto.UUID.generate()) == :error
      assert Threads.fetch_readable(owner("missing"), "not-a-uuid") == :error
    end

    test "writing stays owner-only however wide the tier" do
      {:ok, thread} = Threads.open(owner("write-fence"), "Shared work", visibility: "ledger")
      stranger = owner("stranger-write")

      # The read admits the stranger; the owner-scoped lookup every write and
      # every mint resolves through does not.
      assert {:ok, _thread, :reader} = Threads.fetch_readable(stranger, thread.id)
      assert Threads.get_for_user(stranger, thread.id) == nil
    end
  end

  describe "the account export" do
    test "carries the account's threads, their events, and the tier that governs them" do
      user = owner("export")

      {:ok, thread} =
        Threads.open(user, "Export this transcript",
          repository: "OpenAgentsInc/openagents.com",
          visibility: "ledger"
        )

      {:ok, _thread} =
        Threads.record_event(thread, "tool.ran", %{"tool" => "bash", "status" => "ok"})

      assert {:ok, export} = AccountExport.build(user)
      assert %{"records" => [record]} = export["threads"]

      assert record["id"] == thread.id
      assert record["objective"] == "Export this transcript"
      assert record["repository"] == "OpenAgentsInc/openagents.com"
      # The consent record travels with the data it governs.
      assert record["visibility"] == "ledger"

      types = Enum.map(record["events"], & &1["event_type"])
      assert "thread.opened" in types
      assert "thread.visibility_set" in types
      assert "tool.ran" in types

      # A plugin run is a thread event, so the export reaches it through the
      # thread rather than through a second collection (#206).
      tool_ran = Enum.find(record["events"], &(&1["event_type"] == "tool.ran"))
      assert tool_ran["payload"] == %{"tool" => "bash", "status" => "ok"}
    end

    test "an owner-only thread exports with its default tier stated" do
      user = owner("export-dark")
      {:ok, _thread} = Threads.open(user, "Private work")

      assert {:ok, export} = AccountExport.build(user)
      assert [%{"visibility" => "dark"}] = export["threads"]["records"]
    end
  end

  describe "issue references" do
    test "a thread can name an issue and remain unnamed" do
      user = owner("issue-link")
      repository = repository_fixture()
      issue = issue_fixture(repository, title: "Linked issue")

      assert {:ok, named} =
               Threads.open(user, "Work for the issue", issue_id: issue.id)

      assert named.issue_id == issue.id

      assert {:ok, unnamed} = Threads.open(user, "Work with no issue")
      assert is_nil(unnamed.issue_id)
    end

    test "list_for_issue returns only threads the reader may read" do
      repository = repository_fixture()
      issue = issue_fixture(repository, title: "Issue with threads")
      owner = owner("issue-owner")
      stranger = owner("issue-stranger")

      {:ok, dark} =
        Threads.open(owner, "Owner-only thread", issue_id: issue.id)

      {:ok, ledger} =
        Threads.open(owner, "Ledger thread",
          issue_id: issue.id,
          visibility: "ledger"
        )

      owner_threads = Threads.list_for_issue(issue, owner) |> Enum.map(& &1.id)
      assert dark.id in owner_threads
      assert ledger.id in owner_threads

      stranger_threads =
        Threads.list_for_issue(issue, stranger) |> Enum.map(& &1.id)

      refute dark.id in stranger_threads
      assert ledger.id in stranger_threads
    end
  end
end
