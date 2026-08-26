defmodule OpenAgentsWeb.ReleaseController do
  @moduledoc """
  Serves CLI release artifacts out of the public release bucket.

  The binaries are not in the repository and never will be: a 40 MB executable
  per platform per version turns a clone into a download. They live in a
  world-readable Cloud Storage bucket, and this route is the one durable name
  in front of them, so `https://openagents.com/releases/<name>` keeps working
  when the bucket behind it is renamed or replaced.

  The proxy therefore adds no authority. Every object it serves is already
  readable by anyone who knows the bucket URL, so there is nothing here to
  authenticate and nothing to withhold. It adds a stable URL, the content type
  and cache lifetime the object deserves, and a strict allowlist on the object
  name so that the one path segment a caller controls cannot address anything
  outside the bucket.

  `priv/static/install.sh` is the client this contract exists for, and it is
  the reason `Range` is honoured rather than ignored. For an artifact of 16 MiB
  or more the installer reads `Content-Length` with a `HEAD`, then fetches
  eight ranges concurrently and concatenates them. A ranged request answered
  with `200` and the whole body would produce eight complete copies
  concatenated into one corrupt binary that still passes as a download, so the
  `206` is a correctness requirement rather than an optimization.
  """

  use OpenAgentsWeb, :controller

  import Plug.Conn

  require Logger

  @storage_host "https://storage.googleapis.com"

  # One segment, and a conservative one. Letters, digits, dot, underscore, and
  # hyphen cover every object we publish (`openagents-0.1.0-rc.1-macos-aarch64`,
  # `SHA256SUMS-0.1.0-rc.1`, `stable`) and admit no slash, no percent escape,
  # and no leading dot. The caller controls this segment and it is interpolated
  # into an outbound URL, so the allowlist is the boundary that keeps the
  # request inside the bucket.
  @name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @name_max_bytes 128

  # A ranged request is passed through verbatim, so its shape is checked here
  # rather than trusted. Only the byte-range syntax the installer sends is
  # forwarded; anything else is dropped and the whole object is served.
  @range_pattern ~r/\Abytes=[0-9,\- ]+\z/

  # A version-pinned artifact and its sums file are the same bytes forever, so
  # a client that has one never needs to ask again. A channel pointer is the
  # opposite: `stable` is a name that moves, and caching it for a year would
  # pin every installer that read it to the release it named that day. Getting
  # these two the wrong way round is how a fleet ends up stuck on an old
  # version with no way to tell it otherwise.
  @immutable_cache "public, max-age=31536000, immutable"
  @pointer_cache "public, max-age=60"

  @streamable_statuses [200, 206]

  def show(conn, %{"name" => name}) when is_binary(name) do
    if admitted_name?(name) do
      proxy(conn, name)
    else
      not_found(conn)
    end
  end

  # Anything that does not arrive as one string names no object. The bucket is
  # flat, and a deeper path never reaches here: `releases` is a reserved slug,
  # so the router answers `/releases/a/b` with the site's own 404 page.
  def show(conn, _params), do: not_found(conn)

  defp admitted_name?(name) do
    byte_size(name) <= @name_max_bytes and
      Regex.match?(@name_pattern, name) and
      not String.contains?(name, "..")
  end

  defp proxy(conn, name) do
    url = object_url(name)
    headers = upstream_headers(conn)

    if head_request?(conn) do
      case Req.head(url, request_options(headers)) do
        {:ok, response} -> answer_head(conn, name, response)
        {:error, reason} -> unavailable(conn, name, reason)
      end
    else
      case Req.get(url, request_options(headers) ++ [into: :self]) do
        {:ok, response} -> answer_get(conn, name, response)
        {:error, reason} -> unavailable(conn, name, reason)
      end
    end
  end

  defp answer_head(conn, name, %Req.Response{status: status} = response)
       when status in @streamable_statuses do
    conn
    |> put_artifact_headers(name, response)
    |> send_resp(status, "")
  end

  defp answer_head(conn, name, response), do: refuse(conn, name, response)

  defp answer_get(conn, name, %Req.Response{status: status, body: body} = response)
       when status in @streamable_statuses do
    conn =
      conn
      |> put_artifact_headers(name, response)
      |> send_chunked(status)

    # `body` is a `Req.Response.Async`, so the artifact crosses this process one
    # chunk at a time and a 40 MB binary is never a 40 MB message. A client that
    # walks away mid-download closes the socket; halting cancels the upstream
    # read rather than draining the rest of the object into a closed connection.
    Enum.reduce_while(body, conn, fn data, current_conn ->
      case chunk(current_conn, data) do
        {:ok, next_conn} -> {:cont, next_conn}
        {:error, :closed} -> {:halt, current_conn}
      end
    end)
  end

  defp answer_get(conn, name, %Req.Response{body: %Req.Response.Async{}} = response) do
    Req.cancel_async_response(response)
    refuse(conn, name, response)
  end

  defp answer_get(conn, name, response), do: refuse(conn, name, response)

  defp refuse(conn, _name, %Req.Response{status: 404}), do: not_found(conn)

  # The bucket rejected the range the client asked for. Say so, rather than
  # reporting it as a fault of ours: the client chose the range and is the only
  # party that can choose a different one.
  defp refuse(conn, _name, %Req.Response{status: 416}) do
    conn
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(416, "")
  end

  defp refuse(conn, name, %Req.Response{status: status}) do
    Logger.warning("release object #{name} answered #{status} from the bucket")

    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(502, "The release store did not answer.\n")
  end

  defp unavailable(conn, name, reason) do
    Logger.warning("release object #{name} could not be read: #{failure_kind(reason)}")

    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(502, "The release store did not answer.\n")
  end

  # The kind of failure, never the payload that carried it. A log line records
  # that the bucket was unreachable and how; the exception itself may quote a
  # URL or a header, and `test/openagents/log_safety_test.exs` refuses the shape
  # that would put one in a log.
  defp failure_kind(%Req.TransportError{reason: reason}), do: "transport #{reason}"
  defp failure_kind(%{__struct__: module}), do: inspect(module)
  defp failure_kind(_other), do: "unknown"

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(404, "Not found.\n")
  end

  defp put_artifact_headers(conn, name, response) do
    {type, charset} = content_type(name)

    conn
    |> put_resp_content_type(type, charset)
    |> put_resp_header("cache-control", cache_control(name))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("accept-ranges", "bytes")
    |> copy_upstream_header(response, "content-length")
    |> copy_upstream_header(response, "content-range")
  end

  # `content-length` is set before the response is sent, which is what makes
  # `HEAD` answer with the artifact's real size. Bandit streams a
  # length-delimited body rather than a chunked one once the length is
  # declared, and suppresses the body entirely for a `HEAD`, so the same code
  # path serves both the installer's size probe and its download.
  defp copy_upstream_header(conn, response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> put_resp_header(conn, name, value)
      [] -> conn
    end
  end

  # `Plug.Head` rewrites `HEAD` to `GET` before the router sees the request, so
  # `conn.method` cannot answer this. The adapter still holds the method the
  # client actually sent. An adapter that stops carrying it falls through to
  # `false`, which costs a discarded body rather than a wrong answer.
  defp head_request?(%Plug.Conn{adapter: {_adapter, %{method: "HEAD"}}}), do: true
  defp head_request?(%Plug.Conn{}), do: false

  defp content_type("openagents-" <> _rest), do: {"application/octet-stream", nil}
  defp content_type(_name), do: {"text/plain", "utf-8"}

  defp cache_control("openagents-" <> _rest), do: @immutable_cache
  defp cache_control("SHA256SUMS-" <> _rest), do: @immutable_cache
  defp cache_control(_name), do: @pointer_cache

  defp upstream_headers(conn) do
    # Ask the bucket for the stored bytes. Req negotiates compression by
    # default, and a compressed transfer would make the `content-length` this
    # route forwards describe the encoded body rather than the artifact the
    # client is about to checksum.
    identity = [{"accept-encoding", "identity"}]

    case get_req_header(conn, "range") do
      [range | _rest] ->
        if Regex.match?(@range_pattern, range), do: [{"range", range} | identity], else: identity

      [] ->
        identity
    end
  end

  defp request_options(headers) do
    Keyword.merge(
      [
        headers: headers,
        decode_body: false,
        # The installer already retries by falling back to a serial download,
        # and a retry of a partially streamed body would restart it from the
        # top into a response that is already open.
        retry: false,
        receive_timeout: 60_000
      ],
      Application.get_env(:openagents, :releases_request_options, [])
    )
  end

  defp object_url(name) do
    bucket = Application.fetch_env!(:openagents, :releases_bucket)
    "#{@storage_host}/#{bucket}/#{name}"
  end
end
