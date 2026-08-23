defmodule OpenAgents.Forge.CommitReferences do
  @moduledoc """
  Read issue references out of a commit message.

  Two forms carry a closing reference, and both are in use here:

    * the GitHub-style inline line, `Closes #126`, which is prose rather
      than a `Key: value` trailer, and
    * the trailer form, `Closes: #126`, which sits with the other trailers
      `OpenAgents.Forge.Browse.trailers/1` collects.

  A verb accepts a comma-separated list (`Closes #12, #13`) and the
  cross-repository form (`Closes OpenAgentsInc/openagents.com#12`).

  Every function here is pure and total. It reads a commit message, which is
  attacker-controlled text arriving on the most load-bearing path in the
  application, so it never raises, never runs a query, and never decides
  anything: it returns what the message says and leaves acting on it to
  `OpenAgents.Forge.Pushes`. Anything it cannot parse is simply not a
  reference.
  """

  @typedoc """
  One issue reference read from a commit message. `owner` and `repository`
  are `nil` for the bare `#N` form, which means the repository that received
  the push.
  """
  @type reference_entry :: %{
          verb: String.t() | nil,
          closing?: boolean(),
          owner: String.t() | nil,
          repository: String.t() | nil,
          number: pos_integer()
        }

  # GitHub's closing keywords, all tenses. Matching the full set keeps a
  # commit message that closes an issue on GitHub closing it here too.
  @closing_verbs ~w(close closes closed fix fixes fixed resolve resolves resolved)

  # A commit message is unbounded input. Past this many bytes the message is
  # not a commit message anyone wrote, and scanning it is not worth the time.
  @message_limit 64_000

  # No single commit closes more references than this. The cap bounds the work
  # one push can ask of the issue tracker.
  @reference_limit 32

  # Issue numbers are `integer` primary keys; anything wider is not a number
  # this tracker ever issued.
  @maximum_number 2_147_483_647

  @verb_pattern @closing_verbs |> Enum.join("|")

  # `Closes #12, #13 and OpenAgentsInc/openagents.com#14` — the verb, then the
  # run of references that follows it. The run stops at the first token that
  # is not a reference, a separator, or whitespace.
  @closing_regex Regex.compile!(
                   "(?:^|[^\\w/#-])(#{@verb_pattern}):?\\s+((?:[A-Za-z0-9][\\w.-]*/[A-Za-z0-9][\\w.-]*)?#\\d{1,10}(?:\\s*(?:,|and)\\s*(?:[A-Za-z0-9][\\w.-]*/[A-Za-z0-9][\\w.-]*)?#\\d{1,10})*)",
                   "i"
                 )

  # Every `#N` or `owner/repo#N` occurrence, whatever precedes it. This is the
  # one place a reference is defined; `OpenAgents.Issues.TaskList` reads
  # task-list checkboxes through it rather than carrying a second regex.
  @mention_regex ~r/(?:^|[^\w\/#-])(?:([A-Za-z0-9][\w.-]*)\/([A-Za-z0-9][\w.-]*))?#(\d{1,10})\b/

  @doc "The closing keywords this reader accepts, lowercase."
  @spec closing_verbs() :: [String.t()]
  def closing_verbs, do: @closing_verbs

  @doc """
  Every closing reference in `message`, in the order it appears, deduplicated.

  Returns `[]` for anything that is not a binary, for a message with no
  closing verb, and for a reference whose number is out of range. It never
  raises.

      iex> OpenAgents.Forge.CommitReferences.closing("Ship it\\n\\nCloses #126")
      [%{verb: "closes", closing?: true, owner: nil, repository: nil, number: 126}]
  """
  @spec closing(term()) :: [reference_entry()]
  def closing(message) when is_binary(message) do
    message
    |> clamp()
    |> scan_closing()
    |> Enum.uniq()
    |> Enum.take(@reference_limit)
  rescue
    _unparseable -> []
  end

  def closing(_message), do: []

  @doc """
  Every issue reference in `message`, closing or not.

  `OpenAgents.Issues.TaskList` reads issue and comment bodies for the `#N`
  mentions inside task-list checkboxes, which carry no verb. `closing?` says
  whether a closing keyword introduced the reference, so one scan serves both
  readers.
  """
  @spec all(term()) :: [reference_entry()]
  def all(message) when is_binary(message) do
    clamped = clamp(message)
    closing = scan_closing(clamped)

    mentions =
      Regex.scan(@mention_regex, clamped, capture: :all_but_first)
      |> Enum.flat_map(fn
        [owner, repository, number] -> entry(nil, owner, repository, number)
        _unmatched -> []
      end)

    (closing ++ mentions)
    |> Enum.uniq_by(fn entry -> {entry.owner, entry.repository, entry.number} end)
    |> Enum.take(@reference_limit)
  rescue
    _unparseable -> []
  end

  def all(_message), do: []

  @doc """
  The issue numbers `message` closes in the repository that received it.

  A cross-repository reference is dropped here rather than resolved: closing
  an issue in another repository is a separate decision with its own
  authority question, and guessing wrong closes the wrong issue.
  """
  @spec closing_numbers(term()) :: [pos_integer()]
  def closing_numbers(message) do
    message
    |> closing()
    |> Enum.filter(&same_repository?/1)
    |> Enum.map(& &1.number)
    |> Enum.uniq()
  end

  @doc "Whether a reference names the repository that received the push."
  @spec same_repository?(reference_entry()) :: boolean()
  def same_repository?(%{owner: nil, repository: nil}), do: true
  def same_repository?(_entry), do: false

  # ── internals ────────────────────────────────────────────────────────────

  defp clamp(message) when byte_size(message) > @message_limit,
    do: binary_part(message, 0, @message_limit)

  defp clamp(message), do: message

  defp scan_closing(message) do
    @closing_regex
    |> Regex.scan(message, capture: :all_but_first)
    |> Enum.flat_map(fn
      [verb, run] -> expand_run(verb, run)
      _unmatched -> []
    end)
  end

  defp expand_run(verb, run) do
    normalized = String.downcase(verb)

    Regex.scan(@mention_regex, " " <> run, capture: :all_but_first)
    |> Enum.flat_map(fn
      [owner, repository, number] -> entry(normalized, owner, repository, number)
      _unmatched -> []
    end)
  end

  defp entry(verb, owner, repository, number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 and parsed <= @maximum_number ->
        [
          %{
            verb: verb,
            closing?: not is_nil(verb),
            owner: blank_to_nil(owner),
            repository: blank_to_nil(repository),
            number: parsed
          }
        ]

      _out_of_range ->
        []
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_value), do: nil
end
