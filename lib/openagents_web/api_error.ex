defmodule OpenAgentsWeb.ApiError do
  @moduledoc """
  One error envelope for the issue-family `/api/v3` routes.

  Before this module a caller met six incompatible bodies for the same class of
  failure: `message` for a missing resource, `errors` for a rejected field,
  `error` as a bare string for one refusal and as an object for the next, plus
  the flat `code`/`message`/`request_id` triple the repository routes already
  published. A client could not read one failure and know how to read the next.

  Every refusal from a route classified `:envelope` in
  `OpenAgentsWeb.ApiRouteAuthority` now carries the same six keys:

    * `message` — the human sentence. GitHub clients already read this key, and
      its value for a missing resource is still exactly `"Not Found"`.
    * `code` — one of `codes/0`, stable across releases, for a client that has
      to branch. This is what gives a CLI distinct exit results.
    * `status` — the HTTP status, repeated in the body so a logged envelope is
      self-describing.
    * `documentation_url` — the published contract at `GET /api/v3`, which
      enumerates every code and the routes that use this envelope.
    * `request_id` — the endpoint's `x-request-id`, so a report names one
      request.
    * `errors` — field name to messages. Always present, `{}` when the failure
      is not field-level, so a client parses one shape.

  Keys are only ever added. Two refusals additionally carry the `error` key a
  measured client already reads; pass it through `:legacy` and it is merged
  beside the envelope rather than replacing it.

  Status codes are chosen by `code`, never by the caller, so two controllers
  cannot disagree about what a missing prerequisite is worth. Non-disclosure is
  preserved by construction: a private resource and an absent one both refuse
  with `not_found`, and no code in this table distinguishes them.
  """

  import Plug.Conn, only: [put_status: 2, get_resp_header: 2]

  alias Ecto.Changeset

  # One status per code. A controller names the code; it never names a status.
  @codes %{
    "unauthenticated" => {401, "Requires authentication"},
    "forbidden" => {403, "Forbidden"},
    "agent_participation_forbidden" => {403, "This agent may not participate in this repository"},
    "not_found" => {404, "Not Found"},
    "label_not_on_issue" => {404, "Label does not exist on this issue"},
    "dependency_not_found" => {404, "Not a prerequisite of this issue"},
    "validation_failed" => {422, "Validation Failed"},
    "delete_failed" => {422, "The resource could not be removed"},
    # Fleet promotion (FLEETPROMOTE-001). A caller that scripts a release has to
    # tell "you may not do this" from "someone promoted first" from "those bytes
    # are not in the forge", so each is its own code with its own status.
    "not_operator" => {403, "The credential's account is not a current operator"},
    "idempotency_conflict" => {409, "That idempotency key already names different bytes"},
    "precondition_failed" => {409, "The fleet target changed before this request"},
    "unknown_commit" => {422, "Only a commit pushed to the forge is promotable"},
    # Thread admission (THREAD-001). Holding too many threads open is not a
    # malformed request and not a forbidden one: the same call succeeds once
    # the caller revokes one, so it is the rate-limit status and its own code.
    "thread_quota_reached" => {429, "This account holds the maximum number of open threads"},
    # Push receipts are read from the WAL, not from PostgreSQL, so a storage
    # that will not answer is a temporary unreadability rather than an absence.
    # Reporting it as `not_found` would tell a pusher their push is not on
    # record, which is a different and much worse claim.
    "push_record_unreadable" => {503, "The push record is temporarily unreadable"}
  }

  @doc """
  Every stable error code and the one status it maps to.

  `OpenAgentsWeb.ApiExtensionController` publishes this table at `GET /api/v3`,
  so a client reads the codes it must handle rather than collecting them from
  runtime examples.
  """
  @spec codes() :: %{String.t() => pos_integer()}
  def codes, do: Map.new(@codes, fn {code, {status, _message}} -> {code, status} end)

  @doc "The keys every envelope carries, in the order the contract lists them."
  @spec envelope_keys() :: [String.t()]
  def envelope_keys, do: ~w(message code status documentation_url request_id errors)

  @doc """
  Refuses the request with one stable code.

  Options:

    * `:message` — replaces the code's default sentence. The code and the
      status do not change with it.
    * `:errors` — a field-to-messages map.
    * `:legacy` — a map merged beside the envelope for a client that already
      reads a key this envelope does not define.
  """
  @spec refuse(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def refuse(conn, code, opts \\ []) do
    {status, default_message} = fetch_code!(code)

    body =
      %{
        "message" => Keyword.get(opts, :message, default_message),
        "code" => code,
        "status" => status,
        "documentation_url" => documentation_url(),
        "request_id" => request_id(conn),
        "errors" => field_errors(Keyword.get(opts, :errors, %{}))
      }
      |> Map.merge(Keyword.get(opts, :legacy, %{}))

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(body)
  end

  @doc "Refuses with `not_found`, the only refusal a private resource may make."
  @spec not_found(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def not_found(conn, opts \\ []), do: refuse(conn, "not_found", opts)

  @doc "Refuses with `forbidden`, for an authenticated caller without authority."
  @spec forbidden(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def forbidden(conn, opts \\ []), do: refuse(conn, "forbidden", opts)

  @doc "Refuses with `validation_failed` and the given field-to-messages map."
  @spec validation_failed(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def validation_failed(conn, errors, opts \\ []) do
    refuse(conn, "validation_failed", Keyword.put(opts, :errors, errors))
  end

  @doc """
  Refuses with `validation_failed`, translating a changeset's errors.

  Placeholders are interpolated, so a length violation reads
  `"should be at most 3 character(s)"` rather than leaking `%{count}`.
  """
  @spec changeset(Plug.Conn.t(), Changeset.t(), keyword()) :: Plug.Conn.t()
  def changeset(conn, %Changeset{} = changeset, opts \\ []) do
    validation_failed(conn, Changeset.traverse_errors(changeset, &translate/1), opts)
  end

  @doc """
  The envelope as a plain map, for a plug that refuses before a controller runs.

  A plug halts its own connection, so it needs the body without the send.
  """
  @spec envelope(Plug.Conn.t(), String.t(), keyword()) :: map()
  def envelope(conn, code, opts \\ []) do
    {status, default_message} = fetch_code!(code)

    %{
      "message" => Keyword.get(opts, :message, default_message),
      "code" => code,
      "status" => status,
      "documentation_url" => documentation_url(),
      "request_id" => request_id(conn),
      "errors" => field_errors(Keyword.get(opts, :errors, %{}))
    }
    |> Map.merge(Keyword.get(opts, :legacy, %{}))
  end

  defp fetch_code!(code) do
    case Map.fetch(@codes, code) do
      {:ok, entry} ->
        entry

      :error ->
        raise ArgumentError,
              "#{inspect(code)} is not a stable API error code. " <>
                "Add it to OpenAgentsWeb.ApiError with the status it always carries. " <>
                "Known codes: #{@codes |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
    end
  end

  # Field names arrive as atoms from changesets and as strings from hand-built
  # maps. JSON has one kind of key, so the envelope does too.
  defp field_errors(errors) when is_map(errors) do
    Map.new(errors, fn {field, messages} -> {to_string(field), messages} end)
  end

  defp request_id(conn) do
    conn |> get_resp_header("x-request-id") |> List.first()
  end

  defp documentation_url do
    OpenAgentsWeb.Endpoint.url() |> String.trim_trailing("/") |> Kernel.<>("/api/v3")
  end

  defp translate({message, options}) do
    Regex.replace(~r/%{(\w+)}/, message, fn _whole, key ->
      options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
