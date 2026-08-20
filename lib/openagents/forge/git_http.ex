defmodule OpenAgents.Forge.GitHTTP do
  @moduledoc """
  Git smart-HTTP v0, wrapping the stock git binary ("Spokes got that exactly
  right" — standard packfiles, upstream clients, no custom object format).

  Serves, under the mount point (`/git` in the router):

      GET  /:repo.git/info/refs?service=git-upload-pack|git-receive-pack
      POST /:repo.git/git-upload-pack
      POST /:repo.git/git-receive-pack

  Reads (`upload-pack`) run against the local bare repo after a WAL
  freshness check. Writes (`receive-pack`) go through `OpenAgents.Forge.Pushes`:
  applied locally, then persisted to the WAL — the push is acked only after
  the WAL accepts it (Continuity rule), otherwise refs are rolled back and
  the client sees a failed push.

  Request bodies are bounded and gunzipped when the client says so. The
  `Git-Protocol` header is passed through so protocol v2 works.
  """

  @behaviour Plug

  import Plug.Conn

  alias OpenAgents.Forge.{Pushes, Repos, Sync}

  @max_body_bytes 512 * 1024 * 1024
  @read_chunk 8 * 1024 * 1024

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case {conn.method, split_repo(conn.path_info)} do
      {"GET", {:ok, repo, ["info", "refs"]}} ->
        advertise(conn, repo, first_query(conn, "service"))

      {"POST", {:ok, repo, ["git-upload-pack"]}} ->
        upload_pack(conn, repo)

      {"POST", {:ok, repo, ["git-receive-pack"]}} ->
        receive_pack(conn, repo)

      _other ->
        send_resp(conn, 404, "not found") |> halt()
    end
  end

  # ── routes ──────────────────────────────────────────────────────────────

  defp advertise(conn, repo, service) when service in ["git-upload-pack", "git-receive-pack"] do
    with :ok <- check_repo(repo) do
      Sync.ensure_fresh(repo)
      command = String.trim_leading(service, "git-")
      path = Repos.ensure_repo!(repo)

      {output, 0} =
        run_git_service(command, ["--advertise-refs", path], "", git_protocol(conn))

      header = pkt_line("# service=#{service}\n") <> "0000"

      conn
      |> put_resp_content_type("application/x-#{service}-advertisement")
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, header <> output)
      |> halt()
    else
      {:error, status, message} -> send_resp(conn, status, message) |> halt()
    end
  end

  defp advertise(conn, _repo, _service),
    do: send_resp(conn, 400, "dumb http protocol is not supported") |> halt()

  defp upload_pack(conn, repo) do
    with :ok <- check_repo(repo),
         {:ok, body, conn} <- read_git_body(conn) do
      Sync.ensure_fresh(repo)
      path = Repos.ensure_repo!(repo)
      {output, _status} = run_git_service("upload-pack", [path], body, git_protocol(conn))

      conn
      |> put_resp_content_type("application/x-git-upload-pack-result")
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, output)
      |> halt()
    else
      {:error, status, message} -> send_resp(conn, status, message) |> halt()
    end
  end

  defp receive_pack(conn, repo) do
    with :ok <- check_repo(repo),
         :ok <- check_push_allowed(conn),
         {:ok, body, conn} <- read_git_body(conn) do
      case Pushes.handle_receive_pack(repo, body, principal(conn), git_protocol(conn)) do
        {:ok, output} ->
          conn
          |> put_resp_content_type("application/x-git-receive-pack-result")
          |> put_resp_header("cache-control", "no-cache")
          |> send_resp(200, output)
          |> halt()

        {:error, :wal_persist_failed} ->
          send_resp(conn, 503, "push not persisted; refs rolled back — retry") |> halt()

        {:error, _reason} ->
          send_resp(conn, 500, "push failed") |> halt()
      end
    else
      {:error, status, message} -> send_resp(conn, status, message) |> halt()
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp split_repo([segment | rest]) do
    case String.split(segment, ".git") do
      [name, ""] -> {:ok, name, rest}
      _ -> {:ok, segment, rest}
    end
  end

  defp split_repo(_), do: :error

  defp check_repo(repo) do
    if Repos.valid_name?(repo), do: :ok, else: {:error, 404, "unknown repository"}
  end

  # Pushes require an authenticated principal (set by the router auth plug);
  # a missing principal here means a misconfigured pipeline — refuse.
  defp check_push_allowed(conn) do
    case conn.assigns[:forge_principal] do
      %{} -> :ok
      _ -> {:error, 401, "authentication required"}
    end
  end

  defp principal(conn) do
    case conn.assigns[:forge_principal] do
      %{kind: kind, id: id} -> "#{kind}:#{id}"
      %{kind: kind} -> to_string(kind)
      _ -> "unauthenticated"
    end
  end

  defp git_protocol(conn) do
    case get_req_header(conn, "git-protocol") do
      [value | _] -> value
      [] -> nil
    end
  end

  defp read_git_body(conn) do
    case read_all_body(conn, []) do
      {:ok, body, conn} ->
        case get_req_header(conn, "content-encoding") do
          ["gzip" | _] -> {:ok, safe_gunzip(body), conn}
          _ -> {:ok, body, conn}
        end

      {:error, _} ->
        {:error, 413, "request body too large"}
    end
  end

  defp read_all_body(conn, acc) do
    case read_body(conn, length: @read_chunk, read_length: @read_chunk) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        acc = [chunk | acc]

        if IO.iodata_length(acc) > @max_body_bytes do
          {:error, :too_large}
        else
          read_all_body(conn, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_gunzip(body) do
    :zlib.gunzip(body)
  rescue
    _ -> body
  end

  @doc false
  def pkt_line(data) do
    length = byte_size(data) + 4
    hex = length |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    hex <> data
  end

  @doc """
  Run a git service (`upload-pack` / `receive-pack`) in stateless-rpc mode
  with `input` on stdin, via a temp file so stdin EOF semantics are exact.
  Argv-only; request data never touches a shell string.
  """
  def run_git_service(command, args, input, git_protocol) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "forge-rpc-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.write!(input_path, input)

    env = if git_protocol, do: [{"GIT_PROTOCOL", git_protocol}], else: []

    try do
      # `sh` is used ONLY for stdin redirection of a server-generated temp
      # path; every request-derived value rides argv ("$@"), never the string.
      System.cmd(
        "sh",
        [
          "-c",
          ~s(exec git "$@" < "$FORGE_RPC_INPUT"),
          "sh",
          command,
          "--stateless-rpc"
        ] ++ args,
        env: env ++ [{"FORGE_RPC_INPUT", input_path}]
      )
    after
      File.rm(input_path)
    end
  end

  defp first_query(conn, key) do
    conn.query_string
    |> URI.decode_query()
    |> Map.get(key)
  end
end
