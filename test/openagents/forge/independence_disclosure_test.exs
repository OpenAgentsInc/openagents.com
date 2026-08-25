defmodule OpenAgents.Forge.IndependenceDisclosureTest do
  @moduledoc """
  EXIT-006. A gap the forge records privately and reports publicly as health is
  a gap the forge has hidden.

  The disclosure is only worth publishing if it cannot drift from the thing it
  describes, so every assertion here derives its expectation from the source of
  truth rather than restating it: the export section is compared against
  `OpenAgents.DataRights.ExportInventory`, and the verification section is
  compared against the configured anchor source rather than a constant.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.DataRights.ExportInventory
  alias OpenAgents.Forge.Anchor
  alias OpenAgents.Forge.Independence
  alias OpenAgents.Forge.Repos

  # Every string the disclosure may contain. A repository path, an account id,
  # a node name, or a commit sha reaching this projection fails here, which is
  # STATUS-001's rule applied to the one section that talks about the operator.
  @vocabulary ~w(
    openagents.forge_independence.v1
    docs/forge-operator-independence.md
    single_operator
    tamper_evident
    tamper_evident_published
    /.well-known/openagents-forge-anchor.json
    refs/heads/main
    portable partial blocked not_user_data
  )

  # The projection is briefly cached so anonymous traffic cannot become an rpc
  # storm. A test that publishes an anchor would otherwise leave that state in
  # the cache for whichever test runs next.
  setup do
    :persistent_term.erase({OpenAgents.NetworkStatus, :cache})
    on_exit(fn -> :persistent_term.erase({OpenAgents.NetworkStatus, :cache}) end)
    :ok
  end

  describe "the disclosure derives from the ledger" do
    test "every gap the export ledger records is published, and no other" do
      recorded =
        (ExportInventory.with_status(:partial) ++ ExportInventory.with_status(:blocked))
        |> Enum.map(&%{"family" => Atom.to_string(&1.family), "issue" => &1.issue})
        |> Enum.sort_by(& &1["family"])

      published =
        Independence.projection()["export"]["gaps"]
        |> Enum.map(&Map.take(&1, ["family", "issue"]))

      assert published == recorded
    end

    test "the family counts are the ledger's own counts" do
      export = Independence.projection()["export"]

      assert export["families"] == length(ExportInventory.entries())

      for status <- [:portable, :partial, :blocked, :not_user_data] do
        assert export[Atom.to_string(status)] == length(ExportInventory.with_status(status))
      end
    end
  end

  describe "degraded is decided, not asserted" do
    test "an unpublished anchor is enough on its own to report degraded" do
      projection = Independence.projection()

      refute projection["verification"]["anchor_published"]
      assert projection["verification"]["property"] == "tamper_evident"
      assert projection["verification"]["issue"] == 168
      assert projection["degraded"]
      assert Independence.degraded?()
    end

    test "a plaintext store is enough on its own to report degraded" do
      # #178 closed the export half of the private-data axis. If closing it
      # had quietly taken that axis out of the disjunction, a forge with
      # plaintext columns would report itself independent as soon as the
      # verification axis cleared. Every other axis is handed in clean here,
      # which `degraded?/3` exists for: the projection alone cannot show that
      # this axis is load-bearing, because the others are never clean.
      clean_export = %{"gaps" => []}
      clean_verification = %{"anchor_published" => true, "anchor_witnessed" => true}
      private_data = Independence.projection()["private_data"]

      refute Independence.degraded?(clean_export, clean_verification, %{
               private_data
               | "encrypted_at_rest" => true,
                 "operator_reads_source" => false
             })

      assert Independence.degraded?(clean_export, clean_verification, private_data)
    end

    # The publication state is read from the anchors that exist, not from a
    # flag someone can set, so this test publishes a real one.
    test "publishing an anchor changes the verification claim" do
      {:ok, _anchor} = Anchor.publish()

      verification = Independence.projection()["verification"]

      assert verification["anchor_published"]
      assert verification["property"] == "tamper_evident_published"
      assert verification["anchor"] == Anchor.path()
    end

    # The whole point of ADR 0008: the operator serves the anchor, so
    # publishing it does not make it evidence against the operator. A
    # disclosure that closed the verification axis on publication alone would
    # be claiming exactly what the anchor cannot show.
    test "a published anchor is still not witnessed, and still reports degraded" do
      {:ok, _anchor} = Anchor.publish()

      projection = Independence.projection()

      assert projection["verification"]["anchor_published"]
      refute projection["verification"]["anchor_witnessed"]
      assert projection["verification"]["issue"] == 151
      assert projection["degraded"]
      assert Independence.degraded?()
    end

    test "the export encryption and the plaintext store are published together" do
      # #178 decided that an export can be encrypted to a recipient-held key
      # and that the columns behind it stay plaintext. Publishing the first
      # without the second would let a reader conclude the operator cannot
      # read an export, so the second is what `operator_reads_source` says
      # and it is derived from the first rather than asserted beside it.
      private_data = Independence.projection()["private_data"]

      assert private_data["export_recipient_encryption"]
      refute private_data["encrypted_at_rest"]
      assert private_data["operator_reads_source"]
      assert private_data["access_controlled"]
      assert private_data["issue"] == 193
    end

    test "the export encryption claim is read from the route rather than asserted" do
      # The claim is true exactly while `OpenAgentsWeb.DataController` was
      # compiled against the module that encrypts. Nothing here restates it,
      # so removing the encryption removes the claim in the same commit.
      {:ok, {module, [imports: imports]}} =
        :beam_lib.chunks(:code.which(OpenAgentsWeb.DataController), [:imports])

      assert module == OpenAgentsWeb.DataController

      assert OpenAgents.DataRights.Age in Enum.map(imports, &elem(&1, 0)),
             "EXIT-006 derives `export_recipient_encryption` from this call. If the export " <>
               "route stopped encrypting, the disclosure must stop claiming it."
    end

    test "the account export still takes the account and nothing else" do
      # `access_controlled` is derived from this shape, which is the whole
      # access-control claim for this document: no parameter can widen it.
      assert function_exported?(OpenAgents.DataRights.AccountExport, :build, 1)
      refute function_exported?(OpenAgents.DataRights.AccountExport, :build, 2)
    end
  end

  describe "the disclosure publishes its own distance from the proven revision" do
    # #187 ran the forge 57 commits behind `main` for long enough for six exit
    # surfaces to be proven and absent at the same time, and every tip-shaped
    # check stayed green. The distance is the disclosure's own margin of error,
    # so it is derived from the repository this forge serves rather than
    # restated.
    setup :bare_repository

    test "the distance is the commit count between the running revision and the served head",
         %{shas: shas} do
      # Three commits on `refs/heads/main`. A node running the first is two
      # behind, a node running the head is current, and each answer is a count
      # `git` produced, not a number this test also computes by hand.
      assert %{"known" => true, "behind" => 2} = Independence.deployment(Enum.at(shas, 0))
      assert %{"known" => true, "behind" => 1} = Independence.deployment(Enum.at(shas, 1))
      assert %{"known" => true, "behind" => 0} = Independence.deployment(Enum.at(shas, 2))
    end

    test "the ref the distance is measured to is named" do
      # A distance with no ref names nothing. `RELEASE-004` binds the proof
      # matrix to the candidate sha before `.githooks/pre-push` lets it reach
      # this ref, which is what makes its head the proven revision.
      assert Independence.projection()["deployment"]["proven_ref"] == "refs/heads/main"
    end

    test "a revision this forge never accepted reports no distance" do
      assert %{"known" => false, "behind" => nil} =
               Independence.deployment(String.duplicate("a", 40))
    end

    test "a running revision that is not a commit at all reports no distance" do
      # The packaged image reports `"image"` until a deployment commits a sha.
      # That is a real state, and it must withhold rather than guess.
      assert %{"known" => false, "behind" => nil} = Independence.deployment("image")
      assert %{"known" => false, "behind" => nil} = Independence.deployment(nil)
    end

    test "a forge that does not serve its own repository reports no distance", %{shas: shas} do
      # The bound this section names. A forge withholding its own repository
      # reports nothing here, exactly as `EXIT-005` and `EXIT-006` decline to
      # detect a forge that withholds a log.
      previous = Application.get_env(:openagents, :forge_repos)
      Application.put_env(:openagents, :forge_repos, ["served-by-nobody"])
      on_exit(fn -> Application.put_env(:openagents, :forge_repos, previous) end)

      assert %{"known" => false, "behind" => nil} = Independence.deployment(Enum.at(shas, 0))
    end

    test "neither revision the distance lies between reaches the projection", %{shas: shas} do
      # `STATUS-001` keeps commit shas off this page, and adding one was among
      # the six mutations `EXIT-006`'s proof was confirmed against. A distance
      # is a number and fits; the revisions it is a distance between do not.
      published = strings(Independence.projection()) ++ strings(Independence.deployment(hd(shas)))

      for sha <- shas, published_value <- published do
        refute String.contains?(published_value, sha)
        refute String.contains?(published_value, String.slice(sha, 0, 12))
      end
    end

    test "the distance is read from the served repository rather than asserted" do
      # The same compiled-import-table read `export_recipient_encryption` uses.
      # `OpenAgents.Forge.Repos` is reached from this module for one reason —
      # counting the commits between the running revision and the served head —
      # so a hardcoded distance loses this call in the same commit.
      {:ok, {module, [imports: imports]}} =
        :beam_lib.chunks(:code.which(Independence), [:imports])

      assert module == Independence

      assert OpenAgents.Forge.Repos in Enum.map(imports, &elem(&1, 0)),
             "EXIT-006 derives the deployment distance from a git read of the repository " <>
               "this forge serves. A disclosure that stopped reading it must stop " <>
               "publishing a distance."
    end

    test "being behind is not an independence shortfall" do
      # Deliberate, and recorded in EXIT-006: a node one commit behind is not
      # less independent, and folding ordinary deploy lag into `degraded` would
      # make the verdict mean nothing on the day it mattered. The distance is
      # published beside the verdict, never inside it.
      clean_export = %{"gaps" => []}
      clean_verification = %{"anchor_published" => true, "anchor_witnessed" => true}

      clean_private_data = %{
        "export_recipient_encryption" => true,
        "encrypted_at_rest" => true
      }

      refute Independence.degraded?(clean_export, clean_verification, clean_private_data)
    end
  end

  describe "the disclosure carries no content" do
    test "every string in the projection is a family name, a status, or fixed vocabulary" do
      families = Enum.map(ExportInventory.entries(), &Atom.to_string(&1.family))
      allowed = MapSet.new(@vocabulary ++ families)

      for value <- strings(Independence.projection()) do
        assert MapSet.member?(allowed, value),
               "the independence disclosure published #{inspect(value)}, which is neither a " <>
                 "ledger family nor fixed vocabulary. STATUS-001 keeps content out of this page."
      end
    end
  end

  describe "the surfaces publish it" do
    test "GET /api/status carries the disclosure", %{conn: conn} do
      body = conn |> get(~p"/api/status") |> json_response(200)

      assert body["independence"]["schema"] == "openagents.forge_independence.v1"
      assert body["independence"]["degraded"]
      assert body["independence"]["operator"]["model"] == "single_operator"
      refute body["independence"]["operator"]["mirror_is_authority"]

      # A check reads the distance here without rehearsing a single exit
      # surface, which is what #246 asks of this section.
      assert body["independence"]["deployment"]["proven_ref"] == "refs/heads/main"
      assert is_boolean(body["independence"]["deployment"]["known"])
    end

    test "the status page names the degraded state and every gap", %{conn: conn} do
      conn = put_req_header(conn, "accept", "text/html")
      {:ok, view, _html} = live(conn, ~p"/status")

      assert has_element?(view, "#status-independence")
      assert view |> element("#status-independence-summary") |> render() =~ "degraded"
      assert has_element?(view, "#status-independence-verification")
      assert has_element?(view, "#status-independence-private-data")
      refute has_element?(view, "#status-independence-anchor-witness")

      # A person reads the distance on the page for the same reason: #187 was
      # found by hand, one surface at a time, and nothing said a word.
      assert view |> element("#status-independence-deployment") |> render() =~ "refs/heads/main"

      rendered = render(view)

      for entry <- ExportInventory.with_status(:partial) do
        assert rendered =~ Atom.to_string(entry.family)
      end
    end

    test "a published anchor is named on the page and still called unwitnessed",
         %{conn: conn} do
      Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})
      {:ok, _anchor} = Anchor.publish()
      :persistent_term.erase({OpenAgents.NetworkStatus, :cache})

      conn = put_req_header(conn, "accept", "text/html")
      {:ok, view, _html} = live(conn, ~p"/status")

      assert view |> element("#status-independence-verification") |> render() =~ Anchor.path()

      assert view |> element("#status-independence-anchor-witness") |> render() =~
               "witnessed by nobody"

      assert view |> element("#status-independence-summary") |> render() =~ "degraded"
    end
  end

  # A bare repository this node serves, with three commits on `refs/heads/main`
  # and no working tree — the shape `OpenAgents.Forge.Repos` maintains. The
  # commits are built with plumbing so the fixture never depends on a checkout.
  defp bare_repository(_context) do
    base = Path.join(System.tmp_dir!(), "independence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_repos = Application.get_env(:openagents, :forge_repos)
    Application.put_env(:openagents, :forge_data_dir, base)
    Application.put_env(:openagents, :forge_repos, ["disclosure-fixture"])

    on_exit(fn ->
      restore(:forge_data_dir, previous_data)
      restore(:forge_repos, previous_repos)
      File.rm_rf(base)
    end)

    path = Repos.ensure_repo!("disclosure-fixture")
    {tree, 0} = Repos.git(path, ["hash-object", "-w", "-t", "tree", "/dev/null"])
    tree = String.trim(tree)

    shas =
      Enum.reduce(1..3, [], fn index, acc ->
        parent = if acc == [], do: [], else: ["-p", List.last(acc)]

        {sha, 0} =
          Repos.git(path, ["commit-tree", "-m", "commit #{index}", tree] ++ parent,
            env: commit_identity()
          )

        acc ++ [String.trim(sha)]
      end)

    {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/main", List.last(shas)])

    %{shas: shas}
  end

  defp commit_identity do
    [
      {"GIT_AUTHOR_NAME", "proof"},
      {"GIT_AUTHOR_EMAIL", "proof@example.test"},
      {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
      {"GIT_COMMITTER_NAME", "proof"},
      {"GIT_COMMITTER_EMAIL", "proof@example.test"},
      {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}
    ]
  end

  defp restore(key, nil), do: Application.delete_env(:openagents, key)
  defp restore(key, value), do: Application.put_env(:openagents, key, value)

  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_binary(value), do: [value]
  defp strings(_other), do: []
end
