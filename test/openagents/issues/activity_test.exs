defmodule OpenAgents.Issues.ActivityTest do
  @moduledoc """
  Acceptance for the issue activity read: threads an issue names that a reader
  may read, and receipts reachable from the commits that reference the issue.
  """

  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Forge.BuildReceipt
  alias OpenAgents.Issues
  alias OpenAgents.Issues.Activity
  alias OpenAgents.Issues.ClosingReference
  alias OpenAgents.Repo
  alias OpenAgents.Threads

  @sha String.duplicate("ab", 20)
  @stages ~w(
    compile
    production_compile
    precommit
    cluster
    javascript
    direct_transaction
    relup_topology
    relup
    version_chain
    interrupted_install
    rolling_replacement
    contracts
    staging_infra
    release_smoke
  )

  setup do
    user = repository_user_fixture("activity-reader")
    repository = repository_with_member_fixture(user, %{visibility: "private"}, "owner")
    {:ok, issue} = Issues.create_issue(repository, %{title: "Activity test issue"})
    %{user: user, repository: repository, issue: issue}
  end

  describe "issue activity" do
    test "an issue with no references lists empty threads and receipts", %{
      issue: issue
    } do
      activity = Activity.for_issue(issue)

      assert activity.threads == []
      assert activity.receipts == []
    end

    test "an issue with a referencing commit that has a gate receipt lists it", %{
      repository: repository,
      issue: issue,
      user: user
    } do
      closing_reference(%{repository: repository, issue: issue, user: user}, @sha)

      forge_data =
        Path.join(
          System.tmp_dir!(),
          "openagents-activity-gate-#{System.unique_integer([:positive])}"
        )

      previous = Application.get_env(:openagents, :forge_data_dir)
      Application.put_env(:openagents, :forge_data_dir, forge_data)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:openagents, :forge_data_dir, previous),
          else: Application.delete_env(:openagents, :forge_data_dir)

        File.rm_rf!(forge_data)
      end)

      _receipt = gate_receipt(repository, @sha)

      activity = Activity.for_issue(issue, user)

      assert [entry] = Enum.filter(activity.receipts, &(&1.family == "gates"))
      assert entry.sha == @sha
      assert entry.receipt["schema"] == "openagents.release-gate.v1"
      assert entry.receipt["git_sha"] == @sha
    end

    test "an issue with a referencing commit that has a receipt lists that receipt", %{
      repository: repository,
      issue: issue,
      user: user
    } do
      closing_reference(%{repository: repository, issue: issue, user: user}, @sha)
      build = build_receipt(repository, @sha)

      activity = Activity.for_issue(issue, user)

      assert [entry] = activity.receipts
      assert entry.family == "builds"
      assert entry.sha == @sha
      assert entry.receipt.id == build.id
      assert activity.threads == []
    end

    test "a caller who cannot see the repository does not see its receipts", %{
      repository: repository,
      issue: issue,
      user: user
    } do
      other = repository_user_fixture("activity-stranger")
      closing_reference(%{repository: repository, issue: issue, user: user}, @sha)
      _build = build_receipt(repository, @sha)

      activity = Activity.for_issue(issue, other)

      assert activity.receipts == []
      assert activity.threads == []
    end

    test "issue agent activity includes readable threads and excludes unreadable ones", %{
      issue: issue,
      user: user
    } do
      {:ok, readable} =
        Threads.open(user, "work for this issue", issue_id: issue.id)

      other = repository_user_fixture("other-thread-owner")

      {:ok, _unreadable} =
        Threads.open(other, "someone else's work", issue_id: issue.id)

      activity = Activity.for_issue(issue, user)

      assert [thread] = activity.threads
      assert thread.id == readable.id
      assert activity.receipts == []
    end
  end

  defp closing_reference(%{repository: repository, issue: issue, user: user}, sha) do
    %ClosingReference{}
    |> ClosingReference.changeset(%{
      repository_id: repository.id,
      issue_id: issue.id,
      commit_sha: sha,
      principal: "user:#{user.id}",
      verb: "closes",
      closed: true,
      closed_by_user_id: user.id
    })
    |> Repo.insert!()
  end

  defp build_receipt(repository, sha) do
    %BuildReceipt{}
    |> BuildReceipt.start_changeset(%{
      repo: repository.storage_key,
      sha: sha,
      target_id: Ecto.UUID.generate()
    })
    |> Ecto.Changeset.put_change(:status, "complete")
    |> Repo.insert!()
  end

  defp gate_receipt(repository, sha) do
    bare = OpenAgents.Forge.Repos.bare_path(repository.storage_key)
    path = Path.join([bare, "openagents", "release-gate-receipts", "#{sha}.json"])
    File.mkdir_p!(Path.dirname(path))

    receipt = %{
      "schema" => "openagents.release-gate.v1",
      "git_sha" => sha,
      "status" => "passed",
      "stages" => Map.new(@stages, &{&1, %{"status" => "passed"}})
    }

    File.write!(path, Jason.encode!(receipt))
    receipt
  end
end
