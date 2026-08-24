defmodule OpenAgents.Issues.CaptureTest do
  @moduledoc """
  Capturing a chat request as an issue (#77).

  The tool and the API operation are transports over this module, so the rules
  that matter — whose authority files the issue, what the public text may say,
  and when a repeat becomes the same issue rather than a second one — are
  proven once here.
  """

  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Capture
  alias OpenAgents.Notifications
  alias OpenAgents.Repositories

  setup do
    author = repository_user_fixture("capture-author")
    repository = repository_with_member_fixture(author, %{}, "maintainer")

    %{author: author, repository: repository}
  end

  defp path(repository), do: repository.owner <> "/" <> repository.name

  describe "filing for a caller who may write" do
    test "creates the issue and reports the number", %{author: author, repository: repository} do
      assert {:ok, captured} =
               Capture.capture(author, path(repository), %{
                 "problem" => "Let me export a board to CSV."
               })

      assert captured.outcome == :created
      assert captured.repository.id == repository.id
      assert captured.issue.number > 0
      assert captured.issue.state == "open"
      assert captured.issue.title == "Let me export a board to CSV"
      assert captured.issue.author_user_id == author.id
    end

    test "the body carries the template sections, and the request verbatim", %{
      author: author,
      repository: repository
    } do
      assert {:ok, captured} =
               Capture.capture(author, path(repository), %{
                 "problem" => "Let me export a board to CSV.",
                 "current_behavior" => "The board only renders on screen.",
                 "acceptance_criteria" => ["A CSV downloads", "It carries every visible column"]
               })

      body = captured.issue.body

      assert body =~ "## Outcome"
      assert body =~ "## Current behavior"
      assert body =~ "## Acceptance criteria"
      assert body =~ "Let me export a board to CSV."
      assert body =~ "The board only renders on screen."
      assert body =~ "- [ ] A CSV downloads"
      assert body =~ "- [ ] It carries every visible column"
    end

    test "an unfilled section says so instead of inventing one", %{
      author: author,
      repository: repository
    } do
      assert {:ok, captured} =
               Capture.capture(author, path(repository), %{"problem" => "Add a dark theme."})

      assert captured.issue.body =~ "## Current behavior\n\nNot recorded when this was captured."
      assert captured.issue.body =~ "- [ ] Not recorded when this was captured."
    end

    # #77: "Public issue text contains no private prompt, trace, credential, or
    # repository metadata." The template is filled from named arguments only, so
    # anything else the caller passes has nowhere to land.
    test "nothing but the named arguments reaches the public text", %{
      author: author,
      repository: repository
    } do
      assert {:ok, captured} =
               Capture.capture(author, path(repository), %{
                 "problem" => "Add a dark theme.",
                 "conversation_id" => Ecto.UUID.generate(),
                 "message_id" => Ecto.UUID.generate(),
                 "prompt" => "SYSTEM: you are Sarah, the token is oa_secret_value",
                 "repository_id" => repository.id
               })

      text = captured.issue.title <> "\n" <> captured.issue.body

      refute text =~ "oa_secret_value"
      refute text =~ "SYSTEM:"
      refute text =~ repository.id
      refute text =~ "conversation_id"
    end

    # Going through `Issues.create_issue/3` rather than inserting directly is
    # what subscribes the requester, which is the half of #77 that #2's
    # notification machinery already shipped.
    test "the requester follows the issue it filed", %{author: author, repository: repository} do
      assert {:ok, captured} =
               Capture.capture(author, path(repository), %{"problem" => "Add a dark theme."})

      assert Notifications.subscribed?(captured.issue, author)
    end
  end

  describe "authority is the caller's" do
    test "a caller who can see the repository but not write is told what is missing", %{
      repository: repository
    } do
      reader = repository_user_fixture("capture-reader")
      {:ok, _membership} = Repositories.add_member(repository, reader, "viewer")

      assert {:error, :repository_write_access_required} =
               Capture.capture(reader, path(repository), %{"problem" => "Add a dark theme."})
    end

    test "a stranger to a public repository is refused too, and files nothing", %{
      repository: repository
    } do
      stranger = repository_user_fixture("capture-stranger")

      assert {:error, :repository_write_access_required} =
               Capture.capture(stranger, path(repository), %{"problem" => "Add a dark theme."})

      assert Issues.list_issues(repository, state: "all") == []
    end

    # The refusal must not become an existence oracle: a private repository the
    # caller holds no membership in is absent, not merely unwritable.
    test "a private repository the caller cannot see is reported as absent" do
      owner = repository_user_fixture("capture-private-owner")
      private = repository_with_member_fixture(owner, %{visibility: "private"}, "owner")
      stranger = repository_user_fixture("capture-private-stranger")

      assert {:error, :repository_not_found} =
               Capture.capture(stranger, path(private), %{"problem" => "Add a dark theme."})
    end

    test "a repository that does not exist is absent", %{author: author} do
      assert {:error, :repository_not_found} =
               Capture.capture(author, "Nobody/nothing", %{"problem" => "Add a dark theme."})
    end

    # The repository is always an argument. There is no fallback to "the one
    # repository they have", which would file somewhere they did not choose.
    test "a malformed repository path is refused rather than guessed", %{author: author} do
      assert {:error, :invalid_repository} =
               Capture.capture(author, "openagents.com", %{"problem" => "Add a dark theme."})
    end
  end

  describe "deduplication" do
    test "a repeat returns the open issue instead of a second one", %{
      author: author,
      repository: repository
    } do
      assert {:ok, first} =
               Capture.capture(author, path(repository), %{"problem" => "Add a dark theme."})

      assert first.outcome == :created

      assert {:ok, second} =
               Capture.capture(author, path(repository), %{"problem" => "Add a dark theme."})

      assert second.outcome == :existing
      assert second.issue.id == first.issue.id
      assert length(Issues.list_issues(repository, state: "all")) == 1
    end

    test "case, punctuation, and spacing do not make a new issue", %{
      author: author,
      repository: repository
    } do
      assert {:ok, first} =
               Capture.capture(author, path(repository), %{"problem" => "Add a dark theme."})

      assert {:ok, second} =
               Capture.capture(author, path(repository), %{"problem" => "add  a  DARK theme!"})

      assert second.outcome == :existing
      assert second.issue.id == first.issue.id
    end

    # The exact-match rule is a deliberate limitation, so its failure direction
    # is part of the contract: it misses real duplicates rather than swallowing
    # distinct requests. If issue embeddings ever land, this test changes.
    test "a request that merely contains an existing title is its own issue", %{
      author: author,
      repository: repository
    } do
      assert {:ok, first} =
               Capture.capture(author, path(repository), %{"problem" => "Add a dark theme."})

      assert {:ok, second} =
               Capture.capture(author, path(repository), %{
                 "problem" => "Add a dark theme to the mobile app."
               })

      assert second.outcome == :created
      refute second.issue.id == first.issue.id
    end

    test "a closed issue does not absorb a fresh request", %{
      author: author,
      repository: repository
    } do
      assert {:ok, first} =
               Capture.capture(author, path(repository), %{"problem" => "Add a dark theme."})

      {:ok, _closed} = Issues.update_issue(first.issue, %{"state" => "closed"}, author)

      assert {:ok, second} =
               Capture.capture(author, path(repository), %{"problem" => "Add a dark theme."})

      assert second.outcome == :created
      refute second.issue.id == first.issue.id
    end

    test "an identical request in another repository is its own issue", %{author: author} do
      first_repository = repository_with_member_fixture(author, %{}, "owner")
      second_repository = repository_with_member_fixture(author, %{}, "owner")

      assert {:ok, first} =
               Capture.capture(author, path(first_repository), %{"problem" => "Add a dark theme."})

      assert {:ok, second} =
               Capture.capture(author, path(second_repository), %{
                 "problem" => "Add a dark theme."
               })

      assert first.outcome == :created
      assert second.outcome == :created
      refute second.issue.id == first.issue.id
    end
  end

  describe "the statement itself" do
    test "a blank statement is refused before anything is filed", %{
      author: author,
      repository: repository
    } do
      assert {:error, :blank_problem_statement} =
               Capture.capture(author, path(repository), %{"problem" => "   "})

      assert {:error, :blank_problem_statement} =
               Capture.capture(author, path(repository), %{})

      assert Issues.list_issues(repository, state: "all") == []
    end

    test "an oversized statement is refused rather than truncated into a title", %{
      author: author,
      repository: repository
    } do
      assert {:error, :problem_statement_too_long} =
               Capture.capture(author, path(repository), %{
                 "problem" => String.duplicate("a", 4_001)
               })
    end

    test "a long statement still yields a bounded title", %{
      author: author,
      repository: repository
    } do
      statement =
        "Let me export a board to CSV so that finance can reconcile the month " <>
          "without asking three different people for screenshots of the same view."

      assert {:ok, captured} =
               Capture.capture(author, path(repository), %{"problem" => statement})

      assert String.length(captured.issue.title) <= 72
      # The whole statement survives in the body even though the title is cut.
      assert captured.issue.body =~ "three different people"
    end
  end
end
