defmodule OpenAgents.Box.Client do
  @moduledoc """
  Typed `Req` client for the Box Public API v1 at `ascii.dev`.

  Every function returns `{:ok, body}` for a `2xx` response and a typed
  `{:error, reason}` otherwise. The bearer key comes from the `:box_api_key`
  application setting; an absent key fails closed with `:box_not_configured`
  before any request leaves the host. Desktop and viewer URLs never pass
  through this module: no function requests them, so a token-bearing URL
  cannot reach a caller or a log.

  One secret does leave here by design. `dispatch_run/5` puts an assignment's
  Git credential in the command it sends, because the provider's command API
  takes no environment map and a box environment can only be set at create.
  That function says why the channel is what it is and what bounds it. No log
  this module writes carries that credential: the one path that reads a failed
  dispatch response strikes it out by exact match first.
  """

  require Logger

  @default_base_url "https://ascii.dev/api/box/v1"

  @box_id_pattern ~r/^bx_[23456789abcdefghjkmnpqrstuvwxyz]{8}$/

  @type body :: map()

  @doc "Provisions a new box. The idempotency key makes a retried create safe."
  @spec create_box(map(), String.t()) :: {:ok, body()} | {:error, term()}
  def create_box(attributes, idempotency_key)
      when is_map(attributes) and is_binary(idempotency_key) do
    request(:post, "/boxes", json: attributes, headers: [{"idempotency-key", idempotency_key}])
  end

  @doc "Lists provider Boxes visible to this deployment account."
  @spec list_boxes() :: {:ok, body()} | {:error, term()}
  def list_boxes, do: list_boxes([])

  @spec list_boxes(keyword()) :: {:ok, body()} | {:error, term()}
  def list_boxes(options) when is_list(options), do: request(:get, "/boxes", options)

  @doc "Reads one box's current state and setup status."
  @spec get_box(String.t()) :: {:ok, body()} | {:error, term()}
  def get_box(box_id) when is_binary(box_id), do: get_box(box_id, [])

  @spec get_box(String.t(), keyword()) :: {:ok, body()} | {:error, term()}
  def get_box(box_id, options) when is_binary(box_id) and is_list(options) do
    with :ok <- validate_box_id(box_id), do: request(:get, "/boxes/#{box_id}", options)
  end

  @doc "Stops and archives a box; a snapshot remains available for resume."
  @spec stop_box(String.t()) :: {:ok, body()} | {:error, term()}
  def stop_box(box_id) when is_binary(box_id), do: stop_box(box_id, [])

  @spec stop_box(String.t(), keyword()) :: {:ok, body()} | {:error, term()}
  def stop_box(box_id, options) when is_binary(box_id) and is_list(options) do
    with :ok <- validate_box_id(box_id), do: request(:post, "/boxes/#{box_id}/stop", options)
  end

  @doc "Updates provider box metadata used by lifecycle ownership checks."
  @spec update_box(String.t(), map()) :: {:ok, body()} | {:error, term()}
  def update_box(box_id, attributes) when is_binary(box_id) and is_map(attributes) do
    with :ok <- validate_box_id(box_id) do
      request(:patch, "/boxes/#{box_id}", json: attributes)
    end
  end

  @doc "Runs one shell command on a box and returns its captured result."
  @spec command(String.t(), map()) :: {:ok, body()} | {:error, term()}
  def command(box_id, attributes) when is_binary(box_id) and is_map(attributes) do
    with :ok <- validate_box_id(box_id) do
      request(:post, "/boxes/#{box_id}/commands", json: attributes)
    end
  end

  @doc "Dispatches one detached, idempotent run directory on a box."
  @spec dispatch_run(String.t(), String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def dispatch_run(box_id, run_id, command)
      when is_binary(box_id) and is_binary(run_id) and is_binary(command) do
    dispatch_run(box_id, run_id, command, nil)
  end

  @spec dispatch_run(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, integer()} | {:error, term()}
  def dispatch_run(box_id, run_id, command, run_directory)
      when is_binary(box_id) and is_binary(run_id) and is_binary(command) do
    with {:ok, body} <-
           command(box_id, %{
             "command" => dispatch_command(run_id, command, run_directory),
             "timeoutSeconds" => 30
           }),
         {:ok, pid} <- dispatch_pid_logged(body, box_id, run_id) do
      {:ok, pid}
    end
  end

  @spec dispatch_run(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, integer()} | {:error, term()}
  def dispatch_run(box_id, run_id, command, run_directory, nil),
    do: dispatch_run(box_id, run_id, command, run_directory)

  # The credential travels inside the dispatch command, not beside it. The
  # provider's `CommandRequest` schema is `command`, `cwd`, `timeoutSeconds`,
  # and `detached` — there is no `env`, so an `env` map was accepted with the
  # rest of the request and dropped. The wrapper then read
  # `$OPENAGENTS_FORGE_TOKEN` under `set -u`, died on the unbound variable, and
  # printed no pid, which is the `box_response_invalid` this replaces.
  #
  # `env` on box *create* is a different endpoint and does work, and it is the
  # better channel because the secret never enters a command request. It is not
  # available here: an assignment credential is minted per attempt, long after
  # its box exists, and `PATCH /boxes/{id}` takes only `name`, `ttlSeconds`,
  # and `subdomain`. So this is the documented fallback, and its cost is
  # explicit — the credential is in the provider's request body and in whatever
  # the provider logs of it. It is not in `box_runs.command`, which holds the
  # caller's script and never sees this wrapper, and it is base64 only so that
  # a token cannot break the surrounding shell quoting. That is encoding, not
  # protection. An assignment credential is short-lived and scoped to one
  # branch of one repository, which is what bounds the exposure.
  def dispatch_run(box_id, run_id, command, run_directory, credential)
      when is_binary(box_id) and is_binary(run_id) and is_binary(command) and
             is_binary(run_directory) and is_binary(credential) do
    with {:ok, body} <-
           command(box_id, %{
             "command" => dispatch_command(run_id, command, run_directory, credential),
             "timeoutSeconds" => 30
           }),
         {:ok, pid} <- dispatch_pid_logged(body, box_id, run_id, credential) do
      {:ok, pid}
    end
  end

  @doc "Polls one detached run for output and its exit sentinel."
  @spec poll_run(String.t(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def poll_run(box_id, run_id, offset)
      when is_binary(box_id) and is_binary(run_id) and is_integer(offset) and offset >= 0 do
    poll_run(box_id, run_id, offset, nil)
  end

  @spec poll_run(String.t(), String.t(), non_neg_integer(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def poll_run(box_id, run_id, offset, run_directory)
      when is_binary(box_id) and is_binary(run_id) and is_integer(offset) and offset >= 0 do
    with {:ok, body} <-
           command(box_id, %{
             "command" => poll_command(run_id, offset, run_directory),
             "timeoutSeconds" => 30
           }) do
      {:ok, parse_poll(body)}
    end
  end

  @doc "Probes a detached run directory after an ambiguous dispatch."
  @spec probe_run(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def probe_run(box_id, run_id) when is_binary(box_id) and is_binary(run_id) do
    probe_run(box_id, run_id, nil)
  end

  @spec probe_run(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def probe_run(box_id, run_id, run_directory) when is_binary(box_id) and is_binary(run_id) do
    with {:ok, body} <-
           command(box_id, %{
             "command" => probe_command(run_id, run_directory),
             "timeoutSeconds" => 30
           }) do
      {:ok, parse_probe(body)}
    end
  end

  @doc "Kills the recorded process group for a detached run."
  @spec cancel_run(String.t(), String.t()) :: {:ok, body()} | {:error, term()}
  def cancel_run(box_id, run_id) when is_binary(box_id) and is_binary(run_id) do
    cancel_run(box_id, run_id, nil)
  end

  @spec cancel_run(String.t(), String.t(), String.t() | nil) :: {:ok, body()} | {:error, term()}
  def cancel_run(box_id, run_id, run_directory) when is_binary(box_id) and is_binary(run_id) do
    with {:ok, body} <-
           command(box_id, %{
             "command" => cancel_command(run_id, run_directory),
             "timeoutSeconds" => 30
           }) do
      {:ok, parse_cancel(body)}
    end
  end

  @doc "Whether a string is a well-formed box id."
  @spec valid_box_id?(String.t()) :: boolean()
  def valid_box_id?(box_id) when is_binary(box_id), do: Regex.match?(@box_id_pattern, box_id)
  def valid_box_id?(_box_id), do: false

  defp validate_box_id(box_id) do
    if valid_box_id?(box_id), do: :ok, else: {:error, :box_not_found}
  end

  defp dispatch_command(run_id, command, run_directory) do
    dispatch_command(run_id, command, run_directory, nil)
  end

  defp dispatch_command(run_id, command, run_directory, credential) do
    root = run_root(run_id, run_directory)
    encoded = Base.encode64(command)
    with_credential = is_binary(credential)

    credential_setup =
      if with_credential do
        encoded_credential = Base.encode64("https://x:#{credential}@openagents.com\n")

        """
        umask 077
        printf '%s' '#{encoded_credential}' | base64 -d > "$root/forge-credential"
        git config --file="$root/gitconfig" credential.helper "store --file=$root/forge-credential"
        """
      else
        ""
      end

    launch =
      if with_credential do
        ~s(nohup setsid env GIT_CONFIG_GLOBAL="$root/gitconfig" sh -c 'set +e; sh "$1" > "$2/output.log" 2>&1; status=$?; printf "%s\\n" "$status" > "$2/exit-code"; rm -f "$2/forge-credential" "$2/gitconfig"; exit "$status"' _ "$root/script.sh" "$root" </dev/null >/dev/null 2>&1 &)
      else
        ~s(nohup setsid sh -c 'set +e; sh "$1" > "$2/output.log" 2>&1; status=$?; printf "%s\\n" "$status" > "$2/exit-code"; rm -f "$2/forge-credential" "$2/gitconfig"; exit "$status"' _ "$root/script.sh" "$root" </dev/null >/dev/null 2>&1 &)
      end

    """
    set -eu
    root=#{root}
    mkdir -p "$(dirname "$root")"
    if ! mkdir "$root" 2>/dev/null; then
      printf 'OPENAGENTS_RUN_EXISTS\\n'
      exit 73
    fi
    printf '%s' '#{encoded}' | base64 -d > "$root/script.sh"
    chmod 700 "$root/script.sh"
    : > "$root/output.log"
    #{credential_setup}#{launch}
    pid=$!
    printf '%s\\n' "$pid" > "$root/pid"
    printf '%s\\n' "$pid"
    """
  end

  defp poll_command(run_id, offset, run_directory) do
    root = run_root(run_id, run_directory)

    """
    set -eu
    root=#{root}
    if [ ! -d "$root" ]; then
      printf 'OA_PRESENT=0\\n'
      exit 0
    fi
    size=$(wc -c < "$root/output.log" | tr -d ' ')
    data=$(if [ "$size" -gt #{offset} ]; then dd if="$root/output.log" bs=1 skip=#{offset} 2>/dev/null | base64 -w0; fi)
    printf 'OA_PRESENT=1\\nOA_SIZE=%s\\nOA_DATA=%s\\n' "$size" "$data"
    if [ -f "$root/exit-code" ]; then
      printf 'OA_EXIT=%s\\n' "$(cat "$root/exit-code")"
    fi
    if [ -f "$root/pid" ] && kill -0 "$(cat "$root/pid")" 2>/dev/null; then
      printf 'OA_ALIVE=1\\n'
    else
      printf 'OA_ALIVE=0\\n'
    fi
    """
  end

  defp probe_command(run_id, run_directory) do
    root = run_root(run_id, run_directory)

    """
    set -eu
    root=#{root}
    if [ ! -d "$root" ]; then
      printf 'OA_PRESENT=0\\n'
      exit 0
    fi
    printf 'OA_PRESENT=1\\n'
    if [ -f "$root/pid" ]; then
      printf 'OA_PID=%s\\n' "$(cat "$root/pid")"
    fi
    """
  end

  defp cancel_command(run_id, run_directory) do
    root = run_root(run_id, run_directory)

    """
    set -eu
    root=#{root}
    if [ -f "$root/pid" ]; then
      pid=$(cat "$root/pid")
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      cancelled=1
    elif pkill -TERM -f -- "$root/script.sh" 2>/dev/null; then
      cancelled=1
    else
      cancelled=0
    fi
    rm -f "$root/forge-credential" "$root/gitconfig"
    printf 'OA_CANCELLED=%s\\n' "$cancelled"
    """
  end

  defp run_root(run_id, nil), do: "$HOME/.openagents/box-runs/#{run_id}"
  defp run_root(_run_id, run_directory), do: run_directory

  defp dispatch_pid_logged(body, box_id, run_id, credential \\ nil) do
    case dispatch_pid(body) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :box_response_invalid} = error ->
        log_dispatch_refusal(body, box_id, run_id, credential)
        error
    end
  end

  # A 2xx whose body carries no pid used to be a bare atom, which said nothing
  # about whether the provider refused the request or the wrapper ran and
  # failed. Those are opposite diagnoses, and the exit code plus the first line
  # of stderr separates them in one look.
  #
  # This is an operational event, so it stays bounded and carries no raw
  # command result: the response's top-level keys, the exit code, output sizes,
  # and one truncated stderr line with the assignment credential struck out by
  # exact match. The credential is the one secret that can reach this path, and
  # this function is the one place that holds it.
  defp log_dispatch_refusal(body, box_id, run_id, credential) do
    body = if is_map(body), do: body, else: %{}

    Logger.warning(
      "box_dispatch_response_invalid box_id=#{box_id} run_id=#{run_id} " <>
        "keys=#{body |> Map.keys() |> Enum.sort() |> Enum.join(",")} " <>
        "exit_code=#{inspect(body["exit_code"] || body["exitCode"])} " <>
        "stdout_bytes=#{output_bytes(body["stdout"])} " <>
        "stderr_bytes=#{output_bytes(body["stderr"])} " <>
        "timed_out=#{inspect(body["timed_out"] || body["timedOut"])} " <>
        "stderr_head=#{inspect(stderr_head(body["stderr"], credential))}"
    )
  end

  defp output_bytes(value) when is_binary(value), do: byte_size(value)
  defp output_bytes(_value), do: 0

  defp stderr_head(stderr, credential) when is_binary(stderr) do
    stderr
    |> redact(credential)
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 200)
  end

  defp stderr_head(_stderr, _credential), do: ""

  defp redact(text, credential) when is_binary(credential) and credential != "",
    do: String.replace(text, credential, "[redacted]")

  defp redact(text, _credential), do: text

  defp dispatch_pid(%{"stdout" => output}) when is_binary(output) do
    case Regex.run(~r/(?:\A|\n)(\d+)\s*\z/, output) do
      [_, pid] -> {:ok, String.to_integer(pid)}
      _ -> {:error, :box_response_invalid}
    end
  end

  defp dispatch_pid(%{"pid" => pid}) when is_integer(pid), do: {:ok, pid}
  defp dispatch_pid(%{"pid" => pid}) when is_binary(pid), do: integer_or_nil(pid) |> pid_result()
  defp dispatch_pid(_body), do: {:error, :box_response_invalid}

  defp parse_poll(%{"log_size" => size} = body) when is_integer(size) do
    %{
      present: Map.get(body, "present", true),
      log_size: size,
      output: body["output"] || "",
      exit_status: body["exit_status"],
      alive: Map.get(body, "alive", true)
    }
  end

  defp parse_poll(%{"logSize" => size} = body) when is_integer(size) do
    parse_poll(%{
      "log_size" => size,
      "present" => Map.get(body, "present", true),
      "output" => body["output"] || "",
      "exit_status" => body["exitStatus"] || body["exitCode"],
      "alive" => Map.get(body, "alive", true)
    })
  end

  defp parse_poll(%{"stdout" => output}) when is_binary(output) do
    %{
      present: marker(output, "OA_PRESENT", "0") == "1",
      log_size: marker(output, "OA_SIZE", "0") |> integer_marker(),
      output: output_marker(output),
      exit_status: integer_or_nil(marker(output, "OA_EXIT", nil)),
      alive: marker(output, "OA_ALIVE", "0") == "1"
    }
  end

  defp parse_poll(_body),
    do: %{present: false, log_size: 0, output: "", exit_status: nil, alive: false}

  defp parse_probe(%{"present" => present} = body) do
    %{present: present == true, pid: body["pid"]}
  end

  defp parse_probe(%{"stdout" => output}) when is_binary(output) do
    %{
      present: marker(output, "OA_PRESENT", "0") == "1",
      pid: integer_or_nil(marker(output, "OA_PID", nil))
    }
  end

  defp parse_probe(_body), do: %{present: false, pid: nil}

  defp parse_cancel(%{"stdout" => output} = body) when is_binary(output) do
    if String.contains?(output, "OA_CANCELLED=0") do
      Map.put(body, "cancelled", false)
    else
      Map.put(body, "cancelled", true)
    end
  end

  defp parse_cancel(body), do: body

  defp output_marker(output) do
    case Regex.run(~r/OA_DATA=([A-Za-z0-9+\/=]*)/, output) do
      [_, encoded] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> decoded
          :error -> ""
        end

      _missing ->
        ""
    end
  end

  defp marker(output, key, default) do
    case Regex.run(~r/#{key}=([^\n]*)/, output) do
      [_, value] -> value
      _missing -> default
    end
  end

  defp integer_marker(value), do: String.to_integer(value || "0")

  defp integer_or_nil(nil), do: nil

  defp integer_or_nil(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp pid_result(nil), do: {:error, :box_response_invalid}
  defp pid_result(pid), do: {:ok, pid}

  defp request(method, api_path, options) do
    with {:ok, api_key} <- api_key() do
      settings = Application.get_env(:openagents, :box_api, [])
      base_url = settings[:base_url] || @default_base_url

      request_options =
        (settings[:request_options] || [])
        |> Keyword.put_new(:receive_timeout, settings[:receive_timeout_ms] || 630_000)
        |> Keyword.merge(options)
        |> Keyword.put(:auth, {:bearer, api_key})
        |> Keyword.put_new(:retry, retry_policy(method))
        |> Keyword.put_new(:max_retries, 2)
        |> Keyword.put_new(:retry_log_level, false)

      case Req.request([method: method, url: base_url <> api_path] ++ request_options) do
        {:ok, %Req.Response{status: status, body: body}}
        when status in 200..299 and is_map(body) ->
          {:ok, body}

        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:error, :box_response_invalid}

        {:ok, %Req.Response{status: 401}} ->
          {:error, :box_unauthorized}

        {:ok, %Req.Response{status: status}} when status in [402, 403] ->
          {:error, :box_billing_required}

        {:ok, %Req.Response{status: 404}} ->
          {:error, :box_not_found}

        {:ok, %Req.Response{status: 429}} ->
          {:error, :box_rate_limited}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:box_request_refused, status, error_code(body)}}

        {:error, _transport} ->
          {:error, :box_unreachable}
      end
    end
  end

  # Reads retry transparently; a command is not replayed because a timed-out
  # command may still be running on the box.
  defp retry_policy(:get), do: :safe_transient
  defp retry_policy(_method), do: false

  defp api_key do
    case Application.fetch_env(:openagents, :box_api_key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _missing -> {:error, :box_not_configured}
    end
  end

  defp error_code(%{"code" => code}) when is_binary(code), do: code
  defp error_code(_body), do: "unknown"
end
