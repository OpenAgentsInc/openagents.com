defmodule OpenAgentsWeb.ReleaseControllerTest do
  @moduledoc """
  The contract `priv/static/install.sh` reads.

  The installer resolves a channel, downloads an artifact, and verifies it
  against a sums file, all through `/releases/<name>`. Two parts of that are
  load-bearing beyond the usual "did it return the bytes": a `HEAD` must state
  the artifact's real size, and a ranged request must answer `206` with only
  the range. The installer fetches eight ranges concurrently for anything of
  16 MiB or more and concatenates them, so a `200` with the whole body in reply
  to a range produces eight complete copies in one file — a corrupt binary that
  still looks like a successful download.

  The bucket is stubbed rather than reached. The tests are about what this
  route does with an upstream answer, and a test that needs the network is a
  test that reports someone else's outage as our regression.
  """

  use OpenAgentsWeb.ConnCase, async: false

  @bucket "releases-test-bucket"
  @artifact "openagents-0.1.0-rc.1-macos-aarch64"

  setup do
    original_bucket = Application.get_env(:openagents, :releases_bucket)
    original_options = Application.get_env(:openagents, :releases_request_options)

    Application.put_env(:openagents, :releases_bucket, @bucket)
    Application.put_env(:openagents, :releases_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:openagents, :releases_bucket, original_bucket)
      Application.put_env(:openagents, :releases_request_options, original_options)
    end)

    :ok
  end

  test "an artifact is served as opaque bytes a client may keep forever", %{conn: conn} do
    body = :binary.copy("o", 64)

    Req.Test.stub(__MODULE__, fn upstream ->
      assert upstream.method == "GET"
      assert upstream.host == "storage.googleapis.com"
      assert upstream.request_path == "/#{@bucket}/#{@artifact}"

      # Compression would make the length this route forwards describe the
      # encoded body rather than the bytes the installer checksums.
      assert Plug.Conn.get_req_header(upstream, "accept-encoding") == ["identity"]

      upstream
      |> Plug.Conn.put_resp_header("content-length", "64")
      |> Plug.Conn.send_resp(200, body)
    end)

    conn = get(conn, ~p"/releases/#{@artifact}")

    assert conn.status == 200
    assert conn.resp_body == body
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert get_resp_header(conn, "content-length") == ["64"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "a sums file is readable text a client may keep forever", %{conn: conn} do
    sums = "#{String.duplicate("a", 64)}  #{@artifact}\n"

    Req.Test.stub(__MODULE__, fn upstream ->
      assert upstream.request_path == "/#{@bucket}/SHA256SUMS-0.1.0-rc.1"

      upstream
      |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(sums)))
      |> Plug.Conn.send_resp(200, sums)
    end)

    conn = get(conn, ~p"/releases/SHA256SUMS-0.1.0-rc.1")

    assert conn.status == 200
    assert conn.resp_body == sums
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "a channel pointer is text that expires quickly", %{conn: conn} do
    Req.Test.stub(__MODULE__, fn upstream ->
      assert upstream.request_path == "/#{@bucket}/stable"

      upstream
      |> Plug.Conn.put_resp_header("content-length", "11")
      |> Plug.Conn.send_resp(200, "0.1.0-rc.1\n")
    end)

    conn = get(conn, ~p"/releases/stable")

    assert conn.status == 200
    assert conn.resp_body == "0.1.0-rc.1\n"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    # `stable` is a name that moves. Caching it the way an artifact is cached
    # would pin every installer that read it to the release it named that day.
    assert get_resp_header(conn, "cache-control") == ["public, max-age=60"]
  end

  test "a ranged request is answered with only the range that was asked for", %{conn: conn} do
    Req.Test.stub(__MODULE__, fn upstream ->
      assert Plug.Conn.get_req_header(upstream, "range") == ["bytes=8-15"]

      upstream
      |> Plug.Conn.put_resp_header("content-range", "bytes 8-15/64")
      |> Plug.Conn.put_resp_header("content-length", "8")
      |> Plug.Conn.send_resp(206, "34567890")
    end)

    conn =
      conn
      |> put_req_header("range", "bytes=8-15")
      |> get(~p"/releases/#{@artifact}")

    assert conn.status == 206
    assert conn.resp_body == "34567890"
    assert get_resp_header(conn, "content-range") == ["bytes 8-15/64"]
    assert get_resp_header(conn, "content-length") == ["8"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "a HEAD states the artifact's real size without sending it", %{conn: conn} do
    Req.Test.stub(__MODULE__, fn upstream ->
      # The size probe never asks for the body. Answering the client's `HEAD`
      # with a `GET` upstream would pull 40 MB out of the bucket to throw away.
      assert upstream.method == "HEAD"

      upstream
      |> Plug.Conn.put_resp_header("content-length", "41943040")
      |> Plug.Conn.send_resp(200, "")
    end)

    conn = head(conn, ~p"/releases/#{@artifact}")

    assert conn.status == 200
    assert conn.resp_body == ""
    assert get_resp_header(conn, "content-length") == ["41943040"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
  end

  test "an object the bucket does not hold is a plain 404", %{conn: conn} do
    Req.Test.stub(__MODULE__, fn upstream ->
      Plug.Conn.send_resp(upstream, 404, "<?xml version='1.0'?><Error>NoSuchKey</Error>")
    end)

    conn = get(conn, ~p"/releases/openagents-9.9.9-linux-x86_64")

    assert conn.status == 404
    refute conn.resp_body =~ "NoSuchKey"
  end

  test "a bucket that answers with a fault is not reported as ours", %{conn: conn} do
    Req.Test.stub(__MODULE__, fn upstream ->
      Plug.Conn.send_resp(upstream, 503, "unavailable")
    end)

    conn = get(conn, ~p"/releases/stable")

    assert conn.status == 502
  end

  test "a name outside the allowlist is refused before the bucket is asked" do
    Req.Test.stub(__MODULE__, fn _upstream ->
      flunk("a rejected name reached the bucket")
    end)

    # `..` and a leading dot are refused by shape, and an encoded slash arrives
    # as one segment holding a slash, which the allowlist does not admit.
    for name <- ["..", ".ssh", "a%2Fb", "openagents%200.1.0", "under..dot"] do
      conn = get(build_conn(), "/releases/" <> name)
      assert conn.status == 404, "#{name} was not refused"
    end
  end

  test "every platform the installer can ask for is admitted", %{conn: conn} do
    Req.Test.stub(__MODULE__, fn upstream ->
      Plug.Conn.send_resp(upstream, 200, "bytes")
    end)

    # The musl artifacts carry two more hyphens than any name that existed when
    # the allowlist was written. A pattern tightened later without them in mind
    # would 404 every Alpine install while every other platform kept working.
    for platform <- [
          "macos-aarch64",
          "macos-x86_64",
          "linux-x86_64",
          "linux-x86_64-musl",
          "linux-aarch64",
          "linux-aarch64-musl",
          "windows-x86_64"
        ] do
      name = "openagents-0.1.0-rc.2-#{platform}"
      sibling = "openagents-coder-api-0.1.0-rc.2-#{platform}"

      assert get(conn, ~p"/releases/#{name}").status == 200, "#{name} was refused"
      assert get(conn, ~p"/releases/#{sibling}").status == 200, "#{sibling} was refused"
    end
  end

  test "a deeper path names no object, and the reserved slug is what answers", %{conn: conn} do
    Req.Test.stub(__MODULE__, fn _upstream ->
      flunk("a multi-segment path reached the bucket")
    end)

    assert get(conn, "/releases/openagents/0.1.0").status == 404
  end
end
