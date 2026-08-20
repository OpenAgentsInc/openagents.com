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

  import Ecto.Query
  import Plug.Conn

  alias OpenAgents.Forge.{Pushes, Repos, Sync}
  alias OpenAgents.Repositories

  @max_body_bytes 512 * 1024 * 1024
  @read_chunk 8 * 1024 * 1024

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case {conn.method, split_repo(conn.path_info)} do
      {"GET", {:ok, owner, name, ["info", "refs"]}} ->
        advertise(conn, owner, name, first_query(conn, "service"))

      {"POST", {:ok, owner, name, ["git-upload-pack"]}} ->
        upload_pack(conn, owner, name)

      {"POST", {:ok, owner, name, ["git-receive-pack"]}} ->
        receive_pack(conn, owner, name)

      _other ->
        send_resp(conn, 404, "not found") |> halt()
    end
  end

  # ── routes ──────────────────────────────────────────────────────────────

  defp advertise(conn, owner, name, service)
       when service in ["git-upload-pack", "git-receive-pack"] do
    operation = if service == "git-upload-pack", do: :read, else: :write

    with {:ok, repository} <- resolve_repository(conn, owner, name),
         :ok <- authorize(conn, repository, operation) do
      Sync.ensure_fresh(repository.storage_key, repository.default_branch)
      command = String.trim_leading(service, "git-")
      path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)

      {output, 0} =
        run_git_service(command, ["--advertise-refs", path], "", git_protocol(conn))

      header = pkt_line("# service=#{service}\n") <> "0000"

      conn
      |> put_resp_content_type("application/x-#{service}-advertisement")
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, header <> output)
      |> halt()
    else
      error -> send_git_error(conn, error)
    end
  end

  defp advertise(conn, _owner, _name, _service),
    do: send_resp(conn, 400, "dumb http protocol is not supported") |> halt()

  defp upload_pack(conn, owner, name) do
    with {:ok, repository} <- resolve_repository(conn, owner, name),
         :ok <- authorize(conn, repository, :read),
         {:ok, body, conn} <- read_git_body(conn) do
      Sync.ensure_fresh(repository.storage_key, repository.default_branch)
      path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)
      {output, _status} = run_git_service("upload-pack", [path], body, git_protocol(conn))

      conn
      |> put_resp_content_type("application/x-git-upload-pack-result")
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, output)
      |> halt()
    else
      error -> send_git_error(conn, error)
    end
  end

  defp receive_pack(conn, owner, name) do
    with {:ok, repository} <- resolve_repository(conn, owner, name),
         :ok <- authorize(conn, repository, :write),
         {:ok, body, conn} <- read_git_body(conn) do
      case Pushes.handle_receive_pack(
             repository.storage_key,
             body,
             principal(conn),
             git_protocol(conn)
           ) do
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
      error -> send_git_error(conn, error)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp split_repo([segment | rest]) do
    case strip_git_suffix(segment) do
      {:ok, "openagents.com"} -> {:ok, "OpenAgentsInc", "openagents.com", rest}
      {:ok, name} -> {:ok, nil, name, rest}
      :error -> split_namespaced_repo(segment, rest)
    end
  end

  defp split_repo(_), do: :error

  defp split_namespaced_repo(owner, [segment | rest]) do
    case strip_git_suffix(segment) do
      {:ok, name} -> {:ok, owner, name, rest}
      :error -> :error
    end
  end

  defp split_namespaced_repo(_owner, _rest), do: :error

  defp strip_git_suffix(segment) do
    if String.ends_with?(segment, ".git") and byte_size(segment) > 4 do
      {:ok, String.trim_trailing(segment, ".git")}
    else
      :error
    end
  end

  defp resolve_repository(conn, owner, name) when is_binary(owner) do
    case OpenAgents.Repo.one(repository_query(owner, name)) do
      nil -> repository_not_found(conn)
      repository -> {:ok, repository}
    end
  end

  defp resolve_repository(conn, nil, name) do
    case conn.assigns[:forge_principal] do
      %{kind: kind} when kind in [:operator, :machine] ->
        if Repos.valid_name?(name) do
          {:ok,
           %OpenAgents.Repositories.Repository{
             owner: name,
             name: name,
             storage_key: name,
             default_branch: "main",
             visibility: "private",
             lifecycle_state: "ready"
           }}
        else
          repository_not_found(conn)
        end

      _principal ->
        repository_not_found(conn)
    end
  end

  defp repository_query(owner, name) do
    owner_key = String.downcase(owner)
    name_key = String.downcase(name)

    from repository in OpenAgents.Repositories.Repository,
      join: namespace in assoc(repository, :namespace),
      left_join: namespace_alias in OpenAgents.Repositories.NamespaceAlias,
      on: namespace_alias.namespace_id == namespace.id and namespace_alias.slug_key == ^owner_key,
      where:
        repository.name_key == ^name_key and repository.lifecycle_state == "ready" and
          namespace.state == "active" and
          (namespace.slug_key == ^owner_key or not is_nil(namespace_alias.id)),
      preload: [namespace: namespace]
  end

  defp authorize(_conn, %{visibility: "public"}, :read), do: :ok

  defp authorize(conn, repository, :read) do
    case conn.assigns[:forge_principal] do
      nil -> authentication_required()
      %{kind: :user, user: user} -> member_read(repository, user)
      %{kind: kind} when kind in [:operator, :machine] -> operational_access(repository)
    end
  end

  defp authorize(conn, repository, :write) do
    case conn.assigns[:forge_principal] do
      nil ->
        authentication_required()

      %{kind: :user, user: user} ->
        if Repositories.writable?(repository, user) do
          :ok
        else
          case Repositories.membership_role(repository, user) do
            nil -> {:error, 404, "unknown repository"}
            _read_only -> {:error, 403, "repository is read only"}
          end
        end

      %{kind: kind} when kind in [:operator, :machine] ->
        operational_access(repository)
    end
  end

  defp member_read(repository, user) do
    if Repositories.membership_role(repository, user),
      do: :ok,
      else: {:error, 404, "unknown repository"}
  end

  defp operational_access(repository) do
    if repository.storage_key in Repos.allowed_repos(),
      do: :ok,
      else: {:error, 404, "unknown repository"}
  end

  defp repository_not_found(conn) do
    if conn.assigns[:forge_principal],
      do: {:error, 404, "unknown repository"},
      else: authentication_required()
  end

  defp authentication_required,
    do:
      {:error, 401, "authentication required",
       [{"www-authenticate", ~s(Basic realm="openagents-forge")}]}

  defp send_git_error(conn, {:error, status, message}) do
    conn |> send_resp(status, message) |> halt()
  end

  defp send_git_error(conn, {:error, status, message, headers}) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)

    conn |> send_resp(status, message) |> halt()
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
