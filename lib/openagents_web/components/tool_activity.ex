defmodule OpenAgentsWeb.ToolActivity do
  @moduledoc """
  UI projection of durable tool-step activity: the collapsed event-header title
  says what actually ran, and the expansion carries the bounded durable details.

  Every rendered value is derived here from the already-scrubbed durable step
  row and byte-capped before it reaches a template, which is what keeps
  INVARIANTS.md UI-002 honest: bounded scrubbed values, never provider
  identifiers or private recall content.

  Titles per tool, per the owner's direction on issue #79:

    * `computer_run` — the argv joined as a one-line command string.
    * `computer_agent` — `<agent_id>: <prompt excerpt>`.
    * `github_repo_read` — `read <repository>/<path>`.
    * `conversation_search` — `search "<query>"`.
    * Self-describing tools (`computer_probe`, `computer_list`,
      `github_repo_list`, the memory tools, `module_discover`) keep the current
      human subject sentence.
    * Anything else — the current subject sentence plus a bounded `key=value`
      excerpt of the arguments.
    * A historical step with no durable `raw_arguments` falls back to the
      current subject sentence.
  """

  # One line, byte-capped. The collapsed title is glanceable; the title
  # attribute carries more of the same text; payloads in the expansion get a
  # larger but still hard bound.
  @title_cap 200
  @title_attribute_cap 1_000
  @payload_cap 2_048
  @excerpt_cap 120

  # Tools whose current human subject already says what ran.
  @self_describing ~w(
    computer_probe computer_list github_repo_list module_discover
    memory_list memory_search memory_remember memory_forget memory_correct
  )

  @doc "The collapsed event-header title: what actually ran, one bounded line."
  def title(activity), do: build_title(activity, @title_cap)

  @doc "The same derivation at the title-attribute bound, for hover/full text."
  def title_attribute(activity), do: build_title(activity, @title_attribute_cap)

  @doc """
  A short uppercase status word for rows whose derived title no longer carries
  the status sentence. `succeeded` stays quiet; everything else is stated in
  text so color never carries the outcome alone.
  """
  def status_note(%{status: "succeeded"}), do: nil

  def status_note(%{tool_name: tool_name, status: status} = activity) do
    if derived_title(tool_name, decoded_arguments(activity)),
      do: String.upcase(status),
      else: nil
  end

  @doc "The status sentence built from the tool subject, as shipped today."
  def label(%{tool_name: tool_name, status: status}) do
    subject = subject(tool_name)
    titled_subject = upcase_first(subject)

    case status do
      "requested" -> "Getting ready for #{subject}"
      "running" -> "Working on #{subject}"
      "succeeded" -> "Finished #{subject}"
      "failed" -> "Couldn't finish #{subject}"
      "refused" -> "#{titled_subject} wasn't permitted"
      "cancelled" -> "#{titled_subject} was stopped"
      "unavailable" -> "#{titled_subject} isn't available right now"
      "interrupted" -> "#{titled_subject} was interrupted"
    end
  end

  # Each subject is a plain-English noun phrase that reads naturally after
  # "getting ready for", "working on", and "finished", and as a sentence
  # subject. Sarah is always capitalized.
  def subject("recall_messages"), do: "a look back through this conversation"
  def subject("conversation_search"), do: "a search of your past conversations"
  def subject("conversation_read"), do: "a read-through of an earlier conversation"
  def subject("memory_list"), do: "a review of what Sarah remembers about you"
  def subject("memory_search"), do: "a search of what Sarah remembers about you"
  def subject("memory_remember"), do: "a new memory about you"
  def subject("memory_forget"), do: "removal of a memory about you"
  def subject("memory_correct"), do: "a correction to Sarah's memory about you"
  def subject("github_repo_list"), do: "a look through your GitHub repositories"
  def subject("github_repo_read"), do: "a read of a file from GitHub"
  def subject("computer_list"), do: "a check of your connected computers"
  def subject("computer_probe"), do: "a check of what's installed on your computer"
  def subject("computer_run"), do: "a command on your computer"
  def subject("computer_devin"), do: "a Devin coding task on your computer"
  def subject("computer_agent"), do: "a coding agent task on your computer"
  def subject("module_discover"), do: "a check of what Sarah can do"
  def subject("repo_read"), do: "a read of OpenAgents source code"
  def subject("repo_grep"), do: "a search of OpenAgents source code"
  def subject("repo_list"), do: "a listing of the OpenAgents source tree"
  def subject("code_check"), do: "a syntax and compile check of candidate code"
  def subject("repo_edit"), do: "an edit in this job's clone of the OpenAgents repository"
  def subject("repo_write"), do: "a file written in this job's OpenAgents repository clone"

  def subject("repo_commit_push"),
    do: "a commit pushed to this job's branch on the OpenAgents forge"

  def subject(tool_name), do: "the #{humanized_tool(tool_name)} step"

  @doc "Bounded pretty JSON of the step's durable raw arguments, or nil."
  def arguments_pretty(%{raw_arguments: raw} = activity) when is_binary(raw) do
    case decoded_arguments(activity) do
      nil -> bound_block(raw)
      decoded -> decoded |> Jason.encode!(pretty: true) |> bound_block()
    end
  end

  def arguments_pretty(_activity), do: nil

  @doc "Bounded pretty JSON of a durable result/error map, or nil."
  def payload_pretty(payload) when is_map(payload) and map_size(payload) > 0,
    do: payload |> Jason.encode!(pretty: true) |> bound_block()

  def payload_pretty(_payload), do: nil

  @doc "The terminal executor disclosure line, verbatim, for the expansion."
  def executor_detail(%{status: status, executor_disclosure: disclosure})
      when status in ~w(succeeded failed refused cancelled unavailable interrupted) and
             is_binary(disclosure) and disclosure != "" do
    "EXECUTOR / #{disclosure}"
  end

  def executor_detail(_activity), do: nil

  @doc "The step's lifecycle instants as one bounded line."
  def timeline(activity) do
    [
      {"REQUESTED", Map.get(activity, :requested_at)},
      {"STARTED", Map.get(activity, :started_at)},
      {"COMPLETED", Map.get(activity, :completed_at)}
    ]
    |> Enum.filter(fn {_label, at} -> match?(%DateTime{}, at) end)
    |> Enum.map_join(" · ", fn {label, at} ->
      "#{label} #{at |> DateTime.truncate(:second) |> DateTime.to_iso8601()}"
    end)
    |> case do
      "" -> nil
      line -> line
    end
  end

  @doc "The most recent lifecycle instant, for the hover timestamp."
  def timestamp(activity) do
    Map.get(activity, :completed_at) || Map.get(activity, :started_at) ||
      Map.get(activity, :requested_at)
  end

  @doc "Formats a deep-work duration as h/m/s, e.g. `3m 7s`."
  def duration(%DateTime{} = started_at, %DateTime{} = completed_at) do
    seconds = max(DateTime.diff(completed_at, started_at, :second), 0)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    remainder = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{remainder}s"
      true -> "#{remainder}s"
    end
  end

  def duration(_started_at, _completed_at), do: nil

  # ── Title derivation ────────────────────────────────────────────────────────

  defp build_title(%{tool_name: tool_name} = activity, cap) do
    arguments = decoded_arguments(activity)
    derived = derived_title(tool_name, arguments)
    excerpt = if tool_name in @self_describing, do: nil, else: argument_excerpt(arguments)

    cond do
      is_binary(derived) -> bound_line(derived, cap)
      is_binary(excerpt) -> bound_line("#{label(activity)} · #{excerpt}", cap)
      true -> label(activity)
    end
  end

  defp derived_title("computer_run", %{"argv" => argv}) when is_list(argv) and argv != [] do
    if Enum.all?(argv, &is_binary/1), do: Enum.join(argv, " "), else: nil
  end

  defp derived_title("computer_agent", %{"agent_id" => agent_id, "prompt" => prompt})
       when is_binary(agent_id) and is_binary(prompt) do
    "#{agent_id}: #{prompt}"
  end

  defp derived_title("github_repo_read", %{"repository" => repository, "path" => path})
       when is_binary(repository) and is_binary(path) do
    "read #{repository}/#{path}"
  end

  defp derived_title("conversation_search", %{"query" => query}) when is_binary(query) do
    ~s(search "#{query}")
  end

  defp derived_title(_tool_name, _arguments), do: nil

  defp argument_excerpt(arguments) when is_map(arguments) and map_size(arguments) > 0 do
    arguments
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> "#{key}=#{scalar(value)}" end)
    |> Enum.join(", ")
    |> bound_line(@excerpt_cap)
  end

  defp argument_excerpt(_arguments), do: nil

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp scalar(value), do: Jason.encode!(value)

  defp decoded_arguments(%{raw_arguments: raw}) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _invalid -> nil
    end
  end

  defp decoded_arguments(_activity), do: nil

  # ── Bounding ────────────────────────────────────────────────────────────────

  # One line, byte-capped on a UTF-8 boundary. Rendering scrubbed durable values
  # is sanctioned; rendering them unboundedly is not.
  defp bound_line(text, cap) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> bound_bytes(cap)
  end

  defp bound_block(text), do: bound_bytes(text, @payload_cap)

  defp bound_bytes(text, cap) when byte_size(text) <= cap, do: text

  defp bound_bytes(text, cap) do
    truncated =
      text
      |> String.graphemes()
      |> Enum.reduce_while({0, []}, fn grapheme, {bytes, kept} ->
        next = bytes + byte_size(grapheme)
        if next > cap, do: {:halt, {bytes, kept}}, else: {:cont, {next, [grapheme | kept]}}
      end)
      |> then(fn {_bytes, kept} -> kept |> Enum.reverse() |> Enum.join() end)

    truncated <> "…"
  end

  defp humanized_tool(tool_name) when is_binary(tool_name) do
    cleaned = tool_name |> String.replace(["_", "-", "."], " ") |> String.trim()
    if cleaned == "", do: "requested", else: cleaned
  end

  defp humanized_tool(_tool_name), do: "requested"

  defp upcase_first(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> rest
end
