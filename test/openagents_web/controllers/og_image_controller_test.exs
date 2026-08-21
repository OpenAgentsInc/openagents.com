defmodule OpenAgentsWeb.OgImageControllerTest do
  @moduledoc """
  The card endpoint's contract: signed paths, public-only resolution,
  immutable caching, advisory versions, and a fallback that never errors.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Forge.Repos
  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  @marker_png <<0x89, 0x50, 0x4E, 0x47, "FAKE-CARD-RENDER">>

  setup do
    base = Path.join(System.tmp_dir!(), "og-controller-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous = %{
      data: Application.get_env(:openagents, :forge_data_dir),
      wal: Application.get_env(:openagents, :forge_wal_dir),
      visibility: Application.get_env(:openagents, :forge_public_visibility),
      paths: Application.get_env(:openagents, :forge_public_paths),
      renderer: Application.get_env(:openagents, :og_rasterizer_mfa)
    }

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    Application.put_env(:openagents, :forge_public_visibility, %{"openagents.com" => :l3})
    Application.delete_env(:openagents, :forge_public_paths)

    # Hermetic rendering: the endpoint contract does not depend on librsvg.
    Application.put_env(:openagents, :og_rasterizer_mfa, {__MODULE__, :fake_render, []})

    on_exit(fn ->
      if previous.data,
        do: Application.put_env(:openagents, :forge_data_dir, previous.data),
        else: Application.delete_env(:openagents, :forge_data_dir)

      if previous.wal,
        do: Application.put_env(:openagents, :forge_wal_dir, previous.wal),
        else: Application.delete_env(:openagents, :forge_wal_dir)

      if previous.visibility,
        do: Application.put_env(:openagents, :forge_public_visibility, previous.visibility),
        else: Application.delete_env(:openagents, :forge_public_visibility)

      if previous.paths,
        do: Application.put_env(:openagents, :forge_public_paths, previous.paths),
        else: Application.delete_env(:openagents, :forge_public_paths)

      if previous.renderer,
        do: Application.put_env(:openagents, :og_rasterizer_mfa, previous.renderer),
        else: Application.delete_env(:openagents, :og_rasterizer_mfa)

      File.rm_rf(base)
    end)

    shas = seed_repo("openagents.com")
    repository = Repositories.initial_repository!()

    {:ok, repository: repository, shas: shas}
  end

  def fake_render(_svg), do: {:ok, @marker_png}

  defp signed_url(card) do
    path = OpenAgentsWeb.OG.request_path(card)
    path <> "?sig=" <> OpenAgentsWeb.OG.signature(path)
  end

  test "the static route serves the committed brand card", %{conn: conn} do
    conn = get(conn, "/og/static/card.png")

    assert response(conn, 200) == File.read!(committed_asset_path())
    assert resp_content_type(conn) == "image/png"
    assert cache_control(conn) == "public, max-age=21600, immutable"
  end

  test "a repository card renders with the endpoint's headers and cache policy", %{
    conn: conn,
    repository: repository
  } do
    conn = get(conn, signed_url(OpenAgentsWeb.OG.repo_card_for(repository)))

    assert response(conn, 200) == @marker_png
    assert resp_content_type(conn) == "image/png"
    assert cache_control(conn) == "public, max-age=21600, immutable"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "issue cards render from the public issue path", %{conn: conn} do
    {:ok, issue} = Issues.create_issue(%{"title" => "Carded issue"})
    card = OpenAgentsWeb.OG.issue("OpenAgentsInc", "openagents.com", issue)

    assert response(get(conn, signed_url(card)), 200) == @marker_png
  end

  test "blob cards pass through the same disclosure gate as the file page", %{
    conn: conn,
    repository: _repository
  } do
    card =
      OpenAgentsWeb.OG.blob("OpenAgentsInc", "openagents.com", "README.md", %{
        ref: "main",
        size: 42,
        lines: 2,
        truncated: false
      })

    assert response(get(conn, signed_url(card)), 200) == @marker_png
  end

  test "commit cards render for seeded commits", %{conn: conn, shas: shas} do
    card =
      OpenAgentsWeb.OG.commit(
        "OpenAgentsInc",
        "openagents.com",
        %{sha: shas.first, subject: "First commit", author: "Test Author", committed_at: nil},
        nil
      )

    assert response(get(conn, signed_url(card)), 200) == @marker_png
  end

  test "an invalid signature is refused like every other refusal", %{
    conn: conn,
    repository: repository
  } do
    path = OpenAgentsWeb.OG.request_path(OpenAgentsWeb.OG.repo_card_for(repository))
    unsigned = path
    forged = path <> "?sig=" <> String.duplicate("A", 22)

    refused_unsigned = get(conn, unsigned)
    refused_forged = get(conn, forged)

    assert response(refused_unsigned, 404) == ""
    assert response(refused_forged, 404) == ""
    assert get_resp_header(refused_unsigned, "cache-control") == ["public, max-age=60"]
  end

  test "private and unknown repositories are indistinguishable from signature refusals", %{
    conn: conn
  } do
    {:ok, _private} =
      Repositories.create_repository(%{
        owner: "SecondOrg",
        name: "secret-plans",
        visibility: "private"
      })

    private_card = repo_card_for_path(["SecondOrg", "secret-plans"])
    unknown_card = repo_card_for_path(["NobodyOrg", "never-existed"])

    real_path =
      OpenAgentsWeb.OG.request_path(
        OpenAgentsWeb.OG.repo_card_for(Repositories.initial_repository!())
      )

    bad_signature = real_path <> "?sig=bogus"

    refusals = [
      get(conn, signed_url(private_card)),
      get(conn, signed_url(unknown_card)),
      get(conn, bad_signature)
    ]

    assert Enum.all?(refusals, &(response(&1, 404) == ""))

    bodies = Enum.map(refusals, &response(&1, 404))
    assert length(Enum.uniq(bodies)) == 1
  end

  # The version segment exists so emitted URLs are content-addressed; it is
  # not an authorization input. A stale share with a wrong version still
  # heals to current data as long as its signature covers the path.
  test "versions are advisory: wrong version, valid signature, current card", %{
    conn: conn,
    repository: repository
  } do
    real_path = OpenAgentsWeb.OG.request_path(OpenAgentsWeb.OG.repo_card_for(repository))

    stale_path =
      Regex.replace(~r|^/og/v/[0-9a-f]+|, real_path, "/og/v/deadbeefcafe")

    stale_signed = stale_path <> "?sig=" <> OpenAgentsWeb.OG.signature(stale_path)

    conn = get(conn, stale_signed)
    assert response(conn, 200) == @marker_png
  end

  test "rasterizer failures degrade to the committed fallback card", %{
    conn: conn,
    repository: repository
  } do
    # Environment-independent: a failing renderer must produce the fallback
    # bytes whether or not the host has librsvg installed.
    Application.put_env(:openagents, :og_rasterizer_mfa, {__MODULE__, :failing_render, []})

    conn = get(conn, signed_url(OpenAgentsWeb.OG.repo_card_for(repository)))

    assert response(conn, 200) == File.read!(committed_asset_path())
    assert resp_content_type(conn) == "image/png"

    Application.put_env(:openagents, :og_rasterizer_mfa, {__MODULE__, :fake_render, []})
  end

  def failing_render(_svg), do: {:error, :rasterizer_failed}

  ## Meta-tag presence on the pages that emit them ----------------------------

  test "pages without a card emit honest site-level tags", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(property="og:title" content="OpenAgents")
    assert html =~ ~s(name="twitter:card" content="summary_large_image")
    assert html =~ "og:image"
  end

  test "the repository page emits its own card URL", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com")

    assert html =~
             ~r|property="og:image" content="[^"]*/og/v/[0-9a-f]{12}/repos/OpenAgentsInc/openagents\.com\.png\?sig=|

    assert html =~ ~s(OpenAgentsInc/openagents.com)
  end

  test "an issue page emits an issue-specific card URL", %{conn: conn} do
    {:ok, issue} = Issues.create_issue(%{"title" => "Shared on social"})

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/issues/#{issue.number}")

    assert html =~
             ~r|/og/v/[0-9a-f]{12}/repos/OpenAgentsInc/openagents\.com/issues/#{issue.number}\.png\?sig=|
  end

  ## Helpers ------------------------------------------------------------------

  defp committed_asset_path do
    Application.app_dir(:openagents, "priv/static/images/og-card-default.png")
  end

  defp repo_card_for_path([owner, name]) do
    suffix_card = %OpenAgentsWeb.OG{
      kind: :repo,
      kicker: "#{owner} /",
      heading: name,
      description: nil,
      title: "#{owner}/#{name}",
      page_path: "/#{owner}/#{name}",
      path_suffix: [owner, name]
    }

    suffix_card
  end

  defp cache_control(conn), do: conn |> get_resp_header("cache-control") |> List.first()

  defp resp_content_type(conn) do
    case get_resp_header(conn, "content-type") do
      [value | _] -> value
      [] -> nil
    end
  end

  ## Git fixture ---------------------------------------------------------------

  defp seed_repo(repo_name) do
    path = Repos.ensure_repo!(repo_name)

    readme = write_blob(path, "# OpenAgents\n\nCard fixture.\n")
    sample = write_blob(path, "defmodule Sample do\nend\n")

    lib_tree = mktree(path, "100644 blob #{sample}\tog_sample.ex\n")

    tree =
      mktree(
        path,
        "100644 blob #{readme}\tREADME.md\n" <>
          "040000 tree #{lib_tree}\tlib\n"
      )

    first = commit_tree(path, tree, [], "First commit\n")
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", first])

    %{first: first}
  end

  defp write_blob(path, content) do
    {sha, 0} = git_in(path, ["hash-object", "-w", "--stdin"], content)
    String.trim(sha)
  end

  defp mktree(path, listing) do
    {sha, 0} = git_in(path, ["mktree"], listing)
    String.trim(sha)
  end

  defp commit_tree(path, tree, parent_args, message) do
    {sha, 0} =
      git_in(path, ["commit-tree", tree] ++ parent_args, message,
        env: [
          {"GIT_AUTHOR_NAME", "Test Author"},
          {"GIT_AUTHOR_EMAIL", "author@example.test"},
          {"GIT_COMMITTER_NAME", "Test Author"},
          {"GIT_COMMITTER_EMAIL", "author@example.test"}
        ]
      )

    String.trim(sha)
  end

  defp git_in(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "og-stdin-#{System.unique_integer([:positive])}")
    File.write!(input, stdin)

    try do
      System.cmd(
        "sh",
        ["-c", ~s(exec git "$@" < "$IN"), "git"] ++ args,
        cd: path,
        env: [{"IN", input}] ++ Keyword.get(opts, :env, []),
        stderr_to_stdout: true
      )
    after
      File.rm(input)
    end
  end
end
