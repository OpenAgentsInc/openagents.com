defmodule OpenAgents.IssuesWorkspaceTest do
  @moduledoc """
  What a workspace-wide issue read may return, and how much of it.

  The repository-scoped list is handed a repository the caller has already
  authorized. This one authorizes as it reads, so the interesting questions
  are the ones a per-repository list never has to ask: whether a private
  repository can leak into someone else's result, whether a filter can widen
  the set rather than narrow it, and whether the query stays bounded.
  """
  use OpenAgents.DataCase

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Repo
  alias OpenAgents.Repositories

  setup do
    owner = repository_user_fixture("workspace-owner")
    member = repository_user_fixture("workspace-member")
    outsider = repository_user_fixture("workspace-outsider")

    private = ready_repository!(owner, "workspace-private", "private")
    {:ok, _membership} = Repositories.add_member(private, member, "viewer")

    {:ok, secret} =
      Issues.create_issue(private, %{"title" => "Rotate the signing key"}, owner)

    %{owner: owner, member: member, outsider: outsider, private: private, secret: secret}
  end

  test "a private repository's issue reaches a member", context do
    assert context.secret.id in visible_ids(context.member)
    assert context.secret.id in visible_ids(context.owner)
  end

  test "a private repository's issue does not reach a stranger", context do
    refute context.secret.id in visible_ids(context.outsider)
    assert Issues.count_visible_issues(context.outsider, state: "open") >= 0
  end

  test "a stranger cannot reach it by filtering for it either", context do
    for opts <- [
          [q: "Rotate the signing key"],
          [assignee: context.owner.github_login],
          [author: context.owner],
          [state: "all"]
        ] do
      {issues, _total} = Issues.list_visible_issues_page(context.outsider, opts)

      refute context.secret.id in Enum.map(issues, & &1.id),
             "leaked through #{inspect(opts)}"
    end
  end

  test "losing membership loses the issue", context do
    assert context.secret.id in visible_ids(context.member)

    Repo.delete_all(
      from membership in Repositories.Membership,
        where:
          membership.repository_id == ^context.private.id and
            membership.user_id == ^context.member.id
    )

    refute context.secret.id in visible_ids(context.member)
  end

  test "a public repository's issue reaches everyone", context do
    public = ready_repository!(context.owner, "workspace-public", "public")
    {:ok, issue} = Issues.create_issue(public, %{"title" => "Public business"}, context.owner)

    assert issue.id in visible_ids(context.outsider)
  end

  test "assignee and author narrow rather than widen", context do
    {:ok, mine} =
      Issues.create_issue(
        context.private,
        %{"title" => "Mine", "assignees" => [context.owner.github_login]},
        context.member
      )

    assigned = visible_ids(context.member, assignee: context.owner.github_login)
    authored = visible_ids(context.member, author: context.member)

    assert mine.id in assigned
    refute context.secret.id in assigned

    assert mine.id in authored
    refute context.secret.id in authored
  end

  test "an imported issue counts as opened by the login that opened it", context do
    {:ok, imported} =
      Issues.create_issue(context.private, %{
        "title" => "Filed on GitHub",
        "user" => %{"login" => context.member.github_login}
      })

    assert imported.author_user_id == nil
    assert imported.id in visible_ids(context.member, author: context.member)
  end

  test "the closed state is a filter, not a second query", context do
    {:ok, _closed} =
      Issues.update_issue(context.secret, %{"state" => "closed"}, context.owner)

    refute context.secret.id in visible_ids(context.member, state: "open")
    assert context.secret.id in visible_ids(context.member, state: "closed")
  end

  test "one page is bounded and the page number is clamped", context do
    for index <- 1..(Issues.per_page() + 5) do
      {:ok, _issue} =
        Issues.create_issue(context.private, %{"title" => "Bulk #{index}"}, context.owner)
    end

    {first, total} = Issues.list_visible_issues_page(context.member, state: "open")

    assert length(first) == Issues.per_page()
    assert total > Issues.per_page()

    {second, ^total} = Issues.list_visible_issues_page(context.member, state: "open", page: 2)

    assert second != []
    assert Enum.all?(second, &(&1.id not in Enum.map(first, fn issue -> issue.id end)))

    # A hand-typed page number cannot walk past the ceiling, and a page beyond
    # the results is empty rather than an error.
    {beyond, ^total} =
      Issues.list_visible_issues_page(context.member, state: "open", page: "999999999")

    assert beyond == []
  end

  test "rows arrive with their repository, because the list has to name it", context do
    {[issue | _rest], _total} = Issues.list_visible_issues_page(context.member, state: "open")

    assert issue.repository.owner == context.private.owner
    assert issue.repository.name == context.private.name
  end

  defp visible_ids(user, opts \\ []) do
    {issues, _total} = Issues.list_visible_issues_page(user, Keyword.put_new(opts, :state, "all"))
    Enum.map(issues, & &1.id)
  end

  defp ready_repository!(owner, name, visibility) do
    {:ok, repository, :created} =
      Repositories.create_user_repository(
        owner,
        %{name: name, visibility: visibility},
        "#{name}-key"
      )

    repository
    |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
    |> Repo.update!()
  end
end
