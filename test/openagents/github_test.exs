defmodule OpenAgents.GitHubTest do
  use ExUnit.Case, async: false
  alias OpenAgents.GitHub

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.get_env(:openagents, :github_api)

    Application.put_env(:openagents, :github_api,
      base_url: "https://github-api.internal",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:openagents, :github_api, original) end)
    :ok
  end

  test "repository listing authenticates with the bearer token and bounds each summary" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user/repos"
      assert ["Bearer gho_listing-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["application/vnd.github+json"] = Plug.Conn.get_req_header(conn, "accept")
      assert ["2022-11-28"] = Plug.Conn.get_req_header(conn, "x-github-api-version")
      assert ["OpenAgents"] = Plug.Conn.get_req_header(conn, "user-agent")

      query = URI.decode_query(conn.query_string)
      assert query["per_page"] == "5"
      assert query["sort"] == "pushed"

      Req.Test.json(conn, [
        %{
          "full_name" => "octo/widgets",
          "description" => nil,
          "private" => true,
          "default_branch" => "main",
          "language" => nil,
          "pushed_at" => "2026-08-16T12:00:00Z",
          "clone_url" => "https://x-access-token:leaky@github.com/octo/widgets.git"
        }
      ])
    end)

    assert {:ok, [summary]} = GitHub.list_repositories("gho_listing-token", first: 5)

    assert summary == %{
             "full_name" => "octo/widgets",
             "description" => "",
             "private" => true,
             "default_branch" => "main",
             "language" => "",
             "pushed_at" => "2026-08-16T12:00:00Z"
           }

    refute inspect(summary) =~ "leaky"
  end

  test "current user projects the immutable GitHub identity without provider URLs" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user"
      assert ["Bearer gho_identity-token"] = Plug.Conn.get_req_header(conn, "authorization")

      Req.Test.json(conn, %{
        "id" => 7_654,
        "node_id" => "MDQ6VXNlcjc2NTQ=",
        "login" => "octo-user",
        "name" => "Octavia Example",
        "avatar_url" => "https://avatars.githubusercontent.com/u/7654?v=4",
        "type" => "User",
        "html_url" => "https://github.com/octo-user"
      })
    end)

    assert {:ok, identity} = GitHub.current_user("gho_identity-token")

    assert identity == %{
             "id" => 7_654,
             "node_id" => "MDQ6VXNlcjc2NTQ=",
             "login" => "octo-user",
             "name" => "Octavia Example",
             "avatar_url" => "https://avatars.githubusercontent.com/u/7654?v=4",
             "type" => "User"
           }

    refute Map.has_key?(identity, "html_url")
  end

  test "repository discovery returns bounded pages with immutable owners and permissions" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user/repos"

      query = URI.decode_query(conn.query_string)
      assert query["page"] == "2"
      assert query["per_page"] == "2"
      assert query["affiliation"] == "owner,collaborator,organization_member"

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.test/user/repos?page=3&per_page=2>; rel="next")
      )
      |> Req.Test.json([
        repository_payload(%{
          "id" => 10,
          "full_name" => "acme/widgets",
          "permissions" => %{"admin" => false, "push" => false, "pull" => true}
        })
      ])
    end)

    assert {:ok, page} =
             GitHub.list_repository_page("gho_discovery", page: 2, per_page: 2)

    assert page["page"] == 2
    assert page["per_page"] == 2
    assert page["has_next_page"] == true
    assert page["next_page"] == 3

    assert [repository] = page["items"]
    assert repository["id"] == 10
    assert repository["owner"]["id"] == 9
    assert repository["owner"]["login"] == "acme"

    assert repository["permissions"] == %{
             "admin" => false,
             "maintain" => false,
             "pull" => true,
             "push" => false,
             "triage" => false
           }
  end

  test "active organization memberships expose stable organization IDs and roles" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user/memberships/orgs"

      query = URI.decode_query(conn.query_string)
      assert query == %{"page" => "1", "per_page" => "100", "state" => "active"}

      Req.Test.json(conn, [
        %{
          "state" => "active",
          "role" => "admin",
          "organization" => %{
            "id" => 42,
            "node_id" => "MDEyOk9yZ2FuaXphdGlvbjQy",
            "login" => "open-agents",
            "avatar_url" => "https://avatars.githubusercontent.com/u/42?v=4"
          },
          "url" => "https://api.github.com/user/memberships/orgs/open-agents"
        }
      ])
    end)

    assert {:ok, page} = GitHub.list_active_organization_memberships("gho_orgs")

    assert page["has_next_page"] == false

    assert page["items"] == [
             %{
               "state" => "active",
               "role" => "admin",
               "organization" => %{
                 "id" => 42,
                 "node_id" => "MDEyOk9yZ2FuaXphdGlvbjQy",
                 "login" => "open-agents",
                 "avatar_url" => "https://avatars.githubusercontent.com/u/42?v=4",
                 "type" => "Organization"
               }
             }
           ]
  end

  test "an import source requires read access but does not require administrator access" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/acme/widgets"

      Req.Test.json(
        conn,
        repository_payload(%{
          "id" => 100,
          "permissions" => %{"admin" => false, "push" => false, "pull" => true}
        })
      )
    end)

    assert {:ok, source} = GitHub.get_import_source("gho_reader", "acme/widgets")
    assert source["readable"] == true
    assert source["permissions"]["admin"] == false
    assert source["permissions"]["pull"] == true

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(
        conn,
        repository_payload(%{
          "private" => true,
          "permissions" => %{"admin" => true, "push" => true, "pull" => false}
        })
      )
    end)

    assert {:error, :github_permission_denied} =
             GitHub.get_import_source("gho_no_read", "acme/widgets")
  end

  test "branch and tag pages contain only names and commit object IDs" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/acme/widgets/branches"

      Req.Test.json(conn, [
        %{
          "name" => "main",
          "protected" => true,
          "commit" => %{"sha" => String.duplicate("a", 40)}
        }
      ])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/acme/widgets/tags"

      Req.Test.json(conn, [
        %{"name" => "v1.0.0", "commit" => %{"sha" => String.duplicate("b", 40)}}
      ])
    end)

    assert {:ok, branches} = GitHub.list_branch_page("gho_refs", "acme/widgets")

    assert branches["items"] == [
             %{"name" => "main", "protected" => true, "sha" => String.duplicate("a", 40)}
           ]

    assert {:ok, tags} = GitHub.list_tag_page("gho_refs", "acme/widgets")
    assert tags["items"] == [%{"name" => "v1.0.0", "sha" => String.duplicate("b", 40)}]
  end

  test "reference discovery follows bounded pages and returns a stable digest" do
    main_sha = String.duplicate("a", 40)
    release_sha = String.duplicate("b", 40)
    tag_sha = String.duplicate("c", 40)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/acme/widgets/git/matching-refs/heads/"
      assert URI.decode_query(conn.query_string)["page"] == "1"

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.test/repos/acme/widgets/git/matching-refs/heads/?page=2>; rel="next")
      )
      |> Req.Test.json([
        %{"ref" => "refs/heads/main", "object" => %{"type" => "commit", "sha" => main_sha}}
      ])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert URI.decode_query(conn.query_string)["page"] == "2"

      Req.Test.json(conn, [
        %{"ref" => "refs/heads/release", "object" => %{"type" => "commit", "sha" => release_sha}}
      ])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/acme/widgets/git/matching-refs/tags/"

      Req.Test.json(conn, [
        %{"ref" => "refs/tags/v1", "object" => %{"type" => "tag", "sha" => tag_sha}}
      ])
    end)

    assert {:ok, snapshot} =
             GitHub.list_references("gho_refs", "acme/widgets", per_page: 2, max_pages: 2)

    assert Enum.map(snapshot["refs"], & &1["name"]) == [
             "refs/heads/main",
             "refs/heads/release",
             "refs/tags/v1"
           ]

    assert snapshot["count"] == 3
    assert snapshot["digest"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "reference discovery fails closed instead of silently truncating" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.test/repos/acme/widgets/git/matching-refs/heads/?page=2>; rel="next")
      )
      |> Req.Test.json([
        %{
          "ref" => "refs/heads/main",
          "object" => %{"type" => "commit", "sha" => String.duplicate("a", 40)}
        }
      ])
    end)

    assert {:error, :github_pagination_limit_exceeded} =
             GitHub.list_references("gho_refs", "acme/widgets", max_pages: 1)
  end

  test "LFS warning inputs are conservative, bounded, and omit raw tree data" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/acme/widgets/git/trees/main"
      assert URI.decode_query(conn.query_string) == %{"recursive" => "1"}

      Req.Test.json(conn, %{
        "truncated" => false,
        "tree" => [
          %{"path" => ".gitattributes", "type" => "blob", "size" => 200},
          %{"path" => "assets/.gitattributes", "type" => "blob", "size" => 300},
          %{"path" => ".lfsconfig", "type" => "blob", "size" => 100},
          %{"path" => "movie.bin", "type" => "blob", "size" => 120_000_000},
          %{"path" => "src", "type" => "tree", "size" => nil}
        ]
      })
    end)

    assert {:ok, signals} = GitHub.lfs_warning_inputs("gho_lfs", "acme/widgets", "main")

    assert signals == %{
             "attributes_files" => [".gitattributes", "assets/.gitattributes"],
             "large_blob_count" => 1,
             "lfs_config_present" => true,
             "tree_truncated" => false,
             "warning_recommended" => true
           }
  end

  test "pagination and retained tokens are validated before a provider request" do
    assert {:error, :invalid_pagination} =
             GitHub.list_repository_page("gho_token", page: 0, per_page: 10)

    assert {:error, :invalid_pagination} =
             GitHub.list_repository_page("gho_token", page: 1, per_page: 101)

    assert {:error, :invalid_token} = GitHub.current_user("")
    assert {:error, :invalid_token} = GitHub.current_user(String.duplicate("x", 513))
  end

  test "file reads decode contents, honor the ref, and mark truncation" do
    contents = String.duplicate("x", 70_000)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/octo/widgets/contents/lib/deep%20dir/file.ex"
      assert URI.decode_query(conn.query_string)["ref"] == "release-1"

      Req.Test.json(conn, %{
        "type" => "file",
        "path" => "lib/deep dir/file.ex",
        "size" => 70_000,
        "encoding" => "base64",
        "content" => Base.encode64(contents)
      })
    end)

    assert {:ok, file} =
             GitHub.read_path("gho_t", "octo/widgets", "lib/deep dir/file.ex", "release-1")

    assert file["type"] == "file"
    assert file["truncated"] == true
    assert byte_size(file["content"]) == 65_536
  end

  test "directory reads produce a bounded listing" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/octo/widgets/contents/"
      assert conn.query_string == ""

      Req.Test.json(
        conn,
        Enum.map(1..250, fn index ->
          %{"name" => "f#{index}.ex", "path" => "f#{index}.ex", "type" => "file", "size" => nil}
        end)
      )
    end)

    assert {:ok, listing} = GitHub.read_path("gho_t", "octo/widgets", "", nil)
    assert listing["type"] == "directory"
    assert length(listing["entries"]) == 200
    assert %{"name" => "f1.ex", "size" => 0} = hd(listing["entries"])
  end

  test "provider failures map to safe reasons without touching the network" do
    for {status, reason} <- [
          {401, :github_token_rejected},
          {403, :github_permission_denied},
          {404, :github_not_found},
          {500, :github_request_failed}
        ] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"message" => "no"})
      end)

      assert {:error, ^reason} = GitHub.read_path("gho_t", "octo/widgets", "mix.exs", nil)
    end

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, :github_unavailable} = GitHub.list_repositories("gho_t")
  end

  test "invalid repositories and traversal paths are refused before any request" do
    for repository <- ["", "octo", "octo/", "/widgets", "octo/wid gets", "octo/a/b", "-x/y"] do
      assert {:error, :invalid_repository} = GitHub.read_path("gho_t", repository, "mix.exs")
    end

    for path <- ["../secrets", "lib/../../etc", "lib//nested", ".", "a/./b"] do
      assert {:error, :invalid_repository_path} =
               GitHub.read_path("gho_t", "octo/widgets", path)
    end
  end

  test "binary files that cannot be shown as text are refused" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "type" => "file",
        "path" => "logo.png",
        "size" => 4,
        "encoding" => "base64",
        "content" => Base.encode64(<<255, 254, 253, 252>>)
      })
    end)

    assert {:error, :github_file_not_text} =
             GitHub.read_path("gho_t", "octo/widgets", "logo.png")
  end

  defp repository_payload(overrides) do
    Map.merge(
      %{
        "id" => 100,
        "node_id" => "R_kgDOExample",
        "name" => "widgets",
        "full_name" => "acme/widgets",
        "description" => "Repository description",
        "private" => false,
        "fork" => false,
        "archived" => false,
        "default_branch" => "main",
        "language" => "Elixir",
        "pushed_at" => "2026-08-16T12:00:00Z",
        "size" => 42,
        "owner" => %{
          "id" => 9,
          "node_id" => "MDEyOk9yZ2FuaXphdGlvbjk=",
          "login" => "acme",
          "avatar_url" => "https://avatars.githubusercontent.com/u/9?v=4",
          "type" => "Organization"
        },
        "permissions" => %{
          "admin" => false,
          "maintain" => false,
          "pull" => true,
          "push" => false,
          "triage" => false
        },
        "clone_url" => "https://x-access-token:must-not-leak@github.com/acme/widgets.git"
      },
      overrides
    )
  end
end
