defmodule OpenAgents.Repositories.VisibilityJoinTest do
  @moduledoc """
  The executable enumeration behind REPOSITORY-001's visibility predicate.

  `OpenAgents.Repositories.readable_by/2` is the one predicate that answers who
  may read a repository. REPOSITORY-001 used to say every surface that lists or
  resolves a repository composes it, which was more than its proof covered and
  more than was true: four modules composed it and about thirty joined the
  repositories table. Most of those thirty reach a row by an identifier a
  caller already passed authorization for — a milestone's repository, a stack
  entry's repository, a pull request's repository — and are not deciding
  anything. Because nothing separated the two kinds, a module that *did* decide
  visibility with its own restated join failed no proof.

  The line this file draws, and enforces, is the one issue #175 proposed.

  **A visibility decision** starts from something the caller supplied — an
  `owner` and a `name`, or a listing with no prior authorization — and ends
  with a row. Those go through one of the path resolvers below, or compose
  `readable_by/2` into a listing.

  **An ownership reach** starts from a row the caller was already authorized
  for and follows `repository_id`. It decides nothing and owes nothing.

  Three sets close the first kind:

  1. `OpenAgents.Repositories`'s own `*_by_path*` exports, so a new way to turn
     a caller-supplied path into a row is classified by which predicate it
     applies before anything can call it,
  2. the callers of the two that do not apply the reader's own predicate — the
     unfiltered resolver, and the one that resolves as an anonymous reader —
     read from compiled BEAM import tables,
  3. every site in `lib/` that names the predicate's own terms, read from the
     source tree, so a module that restates the join instead of composing it
     lands in an undeclared file.

  What this does not close: a listing that composes no predicate at all joins
  no term and calls no resolver. REPOSITORY-001 records that residue.
  """

  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  # Every `OpenAgents.Repositories` export that turns a caller-supplied owner
  # and name into a repository row, with the predicate it applies.
  @path_resolvers %{
    {:get_by_path!, 2} => :no_predicate,
    {:get_public_by_path!, 2} => :readable_by_an_anonymous_reader,
    {:get_visible_by_path!, 3} => :readable_by_the_caller,
    {:visible_by_path, 3} => :readable_by_the_caller,
    {:get_writable_by_path!, 3} => :writable_by_the_caller
  }

  # The one caller of the resolver that applies no predicate, and why.
  @unfiltered_callers %{
    OpenAgentsWeb.DeploymentController =>
      "resolves the deployment plane's :workflow, :operator, and :system principals, " <>
        "which are not users and which OpenAgents.Deployments.Authority gates instead"
  }

  # The callers that resolve as an anonymous reader even when a signed-in one
  # is present. Each is a surface whose answer must not vary by reader.
  @anonymous_callers %{
    OpenAgents.Issues => "the public issue behind an owner/repo/number path",
    OpenAgents.Projects => "the public project behind an owner/repo/number path",
    OpenAgentsWeb.CommentController => "an agent actor, which holds no repository membership",
    OpenAgentsWeb.IssueController => "an agent actor, which holds no repository membership",
    OpenAgentsWeb.OgImageController => "an unauthenticated social card"
  }

  # Every module that composes the predicate into a listing. `readable_by/2` is
  # defined in `OpenAgents.Repositories`, and a self-call carries no import
  # edge, so the module that owns the predicate is named rather than derived.
  @composers %{
    OpenAgents.Repositories => "the repository list, its page, and the by-id read",
    OpenAgents.Issues => "the workspace-wide issue list and the started-item read",
    OpenAgents.Projects => "the workspace-wide project list and the project-item reads",
    OpenAgents.Notifications => "the inbox read and the fan-out gate",
    OpenAgents.DataRights.AccountExport =>
      "the pull requests, stacks, and issue dependencies an export may carry"
  }

  # Every site in `lib/` that names the predicate's own terms — a repository's
  # `visibility` or `lifecycle_state` against `"public"` or `"ready"`.
  #
  # `:decides` means the site answers who may reach a repository and states the
  # rule itself rather than composing `readable_by/2`. Each is a deliberate
  # exception with a reason, and adding one is meant to be uncomfortable.
  #
  # `:reaches` means the site reads those fields on a row whose reach was
  # already decided — a provisioning branch, a rendering choice, a system
  # sweep, or a write.
  @predicate_sites %{
    "lib/openagents/repositories.ex" =>
      {:decides, "defines readable_by/2 and the writable path resolver beside it"},
    "lib/openagents/forge/git_http.ex" =>
      {:decides,
       "Git transport admits :operator, :machine, and :assignment principals that " <>
         "readable_by/2 does not model; proven by test/openagents/forge/git_http_test.exs"},
    "lib/openagents/deployments/authority.ex" =>
      {:decides, "the read gate for the deployment plane's non-user principals"},
    "lib/openagents/reputation.ex" =>
      {:decides, "the attestation transparency tier, which is disclosure rather than row reach"},
    "lib/openagents_web/repository_access.ex" =>
      {:decides,
       "a narrower file-level disclosure allowlist layered above row admission, " <>
         "which it takes from Repositories.get_visible_by_path!/3"},
    "lib/openagents/tools/workspace_publication.ex" =>
      {:reaches, "a provisioning guard on a row already checked writable"},
    "lib/openagents/repositories/provisioner.ex" =>
      {:reaches, "writes the ready state at the end of provisioning"},
    "lib/openagents/forge/janitor.ex" =>
      {:reaches, "a system sweep of ready storage keys with no reader"},
    "lib/openagents/forge/assignments.ex" =>
      {:reaches, "a provisioning guard on the row an assignment credential names"},
    "lib/openagents_web/live/home_live.ex" => {:reaches, "renders a provisioning badge"},
    "lib/openagents_web/live/code_repo_live.ex" => {:reaches, "branches on provisioning state"},
    "lib/openagents_web/live/code_blob_live.ex" =>
      {:reaches, "refuses a blob read before provisioning finishes"},
    "lib/openagents_web/controllers/repository_controller.ex" =>
      {:reaches, "answers 201 or 202 by provisioning state"},
    "lib/openagents_web/controllers/repository_import_controller.ex" =>
      {:reaches, "answers 201 or 202 by provisioning state"},
    "lib/openagents_web/controllers/repository_json.ex" =>
      {:reaches, "reports the decision as the permissions.pull field"},
    "lib/openagents_web/controllers/og_image_controller.ex" =>
      {:reaches, "refuses a card before provisioning finishes"}
  }

  # A repository's own visibility terms. `@repository.` is excluded: that is a
  # LiveView assign read inside a template, which renders a decision already
  # made rather than making one.
  @predicate_terms ~r/(visibility|lifecycle_state)\s*(==|:)\s*"(public|ready)"/

  test "the path resolvers are exactly the ones classified by the predicate they apply" do
    actual =
      Repositories.__info__(:functions)
      |> Enum.filter(fn {name, _arity} -> Atom.to_string(name) =~ "by_path" end)

    assert_exact_set(
      actual,
      Map.keys(@path_resolvers),
      "turns a caller-supplied owner and name into a repository row; " <>
        "say which predicate it applies"
    )
  end

  test "only the named surfaces resolve a repository path with no predicate" do
    assert_exact_set(
      callers_of({:get_by_path!, 2}),
      Map.keys(@unfiltered_callers),
      "resolves a repository path with no read predicate"
    )
  end

  test "only the named surfaces resolve a repository path as an anonymous reader" do
    assert_exact_set(
      callers_of({:get_public_by_path!, 2}),
      Map.keys(@anonymous_callers),
      "resolves a repository path as an anonymous reader"
    )
  end

  test "the modules composing the read predicate are exactly the ones named" do
    assert_exact_set(
      [Repositories | callers_of({:readable_by, 2})],
      Map.keys(@composers),
      "composes OpenAgents.Repositories.readable_by/2"
    )
  end

  test "every site naming the predicate's terms is classified" do
    assert_exact_set(
      predicate_sites(),
      Map.keys(@predicate_sites),
      "names a repository's own visibility terms; say whether it decides reach " <>
        "or reads a row whose reach was already decided"
    )
  end

  describe "the resolvers agree because they compose one predicate" do
    setup do
      owner = repository_user_fixture("visibility-join-owner")

      {:ok, repository, :created} =
        Repositories.create_user_repository(
          owner,
          %{name: "half-provisioned", visibility: "public", default_branch: "main"},
          "visibility-join-#{System.unique_integer([:positive])}"
        )

      %{owner: owner, repository: repository}
    end

    test "a public repository that is not ready is not resolved for anyone", context do
      assert context.repository.visibility == "public"
      refute context.repository.lifecycle_state == "ready"

      path = [context.repository.namespace.slug, context.repository.name]

      assert_raise Ecto.NoResultsError, fn ->
        apply(Repositories, :get_public_by_path!, path)
      end

      assert Repositories.visible_by_path(
               context.repository.namespace.slug,
               context.repository.name,
               nil
             ) == nil
    end

    test "an issue in a repository that is not ready resolves nowhere", context do
      {:ok, issue} =
        Issues.create_issue(
          context.repository,
          %{"title" => "Filed before provisioning finished"},
          context.owner
        )

      # The restated join this replaced omitted `lifecycle_state`, so this
      # issue resolved here and nowhere else (REPOSITORY-001).
      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue_by_path!(
          context.repository.namespace.slug,
          context.repository.name,
          issue.number
        )
      end
    end

    test "every membership role the database admits is a reading role", context do
      # `readable_by/2` filters the membership join to `@all_roles`. Removing
      # that filter reddens nothing, because every role the database admits
      # reads — the filter is a guard for a role nobody has added yet. The
      # vocabulary is pinned here instead, so a fifth role fails until someone
      # says whether it reads, and the predicate gets re-checked then.
      assert admitted_membership_roles() == ~w(contributor maintainer owner viewer)

      # And the vocabulary is closed by the database, not by the changeset that
      # also states it.
      {:ok, ready} =
        context.repository
        |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
        |> Repo.update()

      auditor = repository_user_fixture("visibility-join-auditor")

      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               Repo.query(
                 """
                 INSERT INTO repository_memberships (repository_id, user_id, role, inserted_at, updated_at)
                 VALUES ($1, $2, 'auditor', now(), now())
                 """,
                 [Ecto.UUID.dump!(ready.id), Ecto.UUID.dump!(auditor.id)]
               )

      assert constraint == "repository_memberships_role_check"
    end

    test "a private repository reaches its member and no one else", context do
      {:ok, private, :created} =
        Repositories.create_user_repository(
          context.owner,
          %{name: "members-only", visibility: "private", default_branch: "main"},
          "visibility-join-private-#{System.unique_integer([:positive])}"
        )

      {:ok, ready} = mark_ready(private)
      stranger = repository_user_fixture("visibility-join-stranger")
      slug = private.namespace.slug

      assert %{id: id} = Repositories.visible_by_path(slug, ready.name, context.owner)
      assert id == ready.id
      assert Repositories.visible_by_path(slug, ready.name, stranger) == nil
      assert Repositories.visible_by_path(slug, ready.name, nil) == nil
    end
  end

  # ── population ──────────────────────────────────────────────────────────

  # Read from each compiled module's import table rather than from source text,
  # so a comment cannot add a caller and an alias cannot hide one.
  defp callers_of({function, arity}) do
    {:ok, modules} = :application.get_key(:openagents, :modules)
    wanted = {Repositories, function, arity}

    Enum.filter(modules, fn module ->
      with path when is_list(path) <- :code.which(module),
           {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
        wanted in imports
      else
        _unreadable -> false
      end
    end)
  end

  # Read from the source tree, because a restated join is text a person wrote
  # and there is no import edge to find it by.
  defp predicate_sites do
    root = Path.expand("../../..", __DIR__)

    Path.wildcard(Path.join(root, "lib/**/*.{ex,exs}"))
    |> Enum.filter(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "@repository."))
      |> Enum.any?(&Regex.match?(@predicate_terms, &1))
    end)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  # Read from the check constraint the database enforces, not from the module
  # attribute the query also names.
  defp admitted_membership_roles do
    %{rows: [[definition]]} =
      Repo.query!("""
      SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conname = 'repository_memberships_role_check'
      """)

    Regex.scan(~r/'([a-z_]+)'/, definition) |> Enum.map(&List.last/1) |> Enum.sort()
  end

  defp mark_ready(repository) do
    repository
    |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp assert_exact_set(actual, declared, what) do
    actual = MapSet.new(actual)
    declared = MapSet.new(declared)

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           Something that #{what} is not named in
           test/openagents/repositories/visibility_join_test.exs. Amend
           REPOSITORY-001 in INVARIANTS.md, then add it here.
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           This test names something that no longer #{what}. Amend
           REPOSITORY-001 in INVARIANTS.md, then remove it here.
           """
  end
end
