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
      assert ["OpenAgents-Sarah"] = Plug.Conn.get_req_header(conn, "user-agent")

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
end
