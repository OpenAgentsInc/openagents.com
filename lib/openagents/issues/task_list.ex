defmodule OpenAgents.Issues.TaskList do
  @moduledoc """
  Render the Markdown task-list checkboxes in an issue or comment body.

  A tracking issue writes its delivery slice as task-list items that point at
  other issues:

      - [ ] #6 Read the legacy schema
      - [ ] #7 Import the boards

  The checkbox is not an independent fact. It restates whether the referenced
  issue is closed, and a restatement drifts. `render/2` removes the drift by
  making the checkbox a projection: given a body and the current state of the
  issues it names, it returns the body that state implies.

  Two properties follow from writing it that way, and both are load-bearing.

    * **Idempotent.** `render/2` is a pure function of the body and the state
      map, so rendering an already-rendered body returns the identical binary.
      Nothing downstream has to remember whether it ran.
    * **Convergent.** Two writers that render the same body against the same
      states produce the same result, so an automatic edit and a human edit
      that cross cannot leave the body describing two different truths.

  Reference extraction is not duplicated here. `OpenAgents.Forge.CommitReferences.all/1`
  already reads every `#N` in a stretch of text, closing or not, with the
  cross-repository form separated out; this module calls it once per task-list
  item and owns only the checkbox.

  Every function is pure and total. Bodies are user-supplied text, so nothing
  here raises, queries, or decides: an unreadable body renders to itself.

  ## What is left alone

  A line is rewritten only when it is a task-list item and every reference in
  it resolves. Anything else keeps the characters the author typed:

    * a `#N` outside a task-list item, including a bare mention in prose;
    * an item naming `owner/repo#N`, because this repository cannot see that
      issue's state and guessing would be worse than staleness;
    * an item naming a number that does not exist in the repository; and
    * an item naming several issues where any one of them is unknown.

  An item naming several issues is checked when all of them are closed. That
  is the only reading under which the checkbox stays a projection: checking on
  the first close would claim work that is still open.
  """

  alias OpenAgents.Forge.CommitReferences

  @typedoc "The state of each referenced issue, by number: `\"open\"` or `\"closed\"`."
  @type states :: %{optional(pos_integer()) => String.t()}

  # A GitHub-flavoured Markdown task-list item: optional indent, a bullet or
  # an ordered marker, the checkbox, and at least one space after it. The
  # trailing space is what separates `- [x] done` from `- [x]done`, which
  # renders as literal text rather than a checkbox.
  @item_regex ~r/\A(\s{0,16}(?:[-*+]|\d{1,9}[.)])[ \t]+\[)([ xX])(\][ \t].*)\z/

  # Past this many bytes the body is not a task list anyone maintains by hand,
  # and splitting it into lines is not work worth doing on a write path. Such a
  # body renders to itself. The limit matches the commit-message clamp in
  # `CommitReferences`.
  @body_limit 64_000

  # No body drives more distinct issue lookups than this.
  @number_limit 128

  @doc """
  The same-repository issue numbers that task-list items in `body` name.

  Returns `[]` for a non-binary body, for an oversized body, and for a body
  whose `#N` references all sit outside task-list items. The caller uses this
  to load exactly the states `render/2` needs, and to skip a body that names
  nothing.

      iex> OpenAgents.Issues.TaskList.numbers("- [ ] #6\\n\\nSee #7 for context.")
      [6]
  """
  @spec numbers(term()) :: [pos_integer()]
  def numbers(body) when is_binary(body) and byte_size(body) <= @body_limit do
    body
    |> String.split("\n")
    |> Enum.flat_map(&line_numbers/1)
    |> Enum.uniq()
    |> Enum.take(@number_limit)
  rescue
    _unreadable -> []
  end

  def numbers(_body), do: []

  @doc """
  `body` with every resolvable task-list checkbox set from `states`.

  `states` maps an issue number to `"open"` or `"closed"`. A number absent
  from the map is unknown, and its item is left as the author wrote it.

      iex> OpenAgents.Issues.TaskList.render("- [ ] #6", %{6 => "closed"})
      "- [x] #6"

      iex> OpenAgents.Issues.TaskList.render("- [x] #6", %{6 => "closed"})
      "- [x] #6"
  """
  @spec render(term(), term()) :: term()
  def render(body, states)
      when is_binary(body) and byte_size(body) <= @body_limit and is_map(states) do
    body
    |> String.split("\n")
    |> Enum.map_join("\n", &render_line(&1, states))
  rescue
    _unrenderable -> body
  end

  def render(body, _states), do: body

  # ── internals ────────────────────────────────────────────────────────────

  defp line_numbers(line) do
    case item(line) do
      {_prefix, _mark, rest} ->
        rest
        |> CommitReferences.all()
        |> Enum.filter(&CommitReferences.same_repository?/1)
        |> Enum.map(& &1.number)

      :no_item ->
        []
    end
  end

  defp render_line(line, states) do
    case item(line) do
      {prefix, mark, rest} ->
        case desired(rest, states) do
          {:ok, target} ->
            if checked?(mark) == target, do: line, else: prefix <> mark(target) <> rest

          :unresolved ->
            line
        end

      :no_item ->
        line
    end
  end

  defp item(line) do
    case Regex.run(@item_regex, line, capture: :all_but_first) do
      [prefix, mark, rest] -> {prefix, mark, rest}
      _no_match -> :no_item
    end
  end

  # `{:ok, checked?}` only when every reference in the item resolves inside
  # this repository. A cross-repository reference stops the whole item rather
  # than being skipped past: an item that names one issue here and one
  # elsewhere is not a claim this repository can settle on its own.
  defp desired(rest, states) do
    references = CommitReferences.all(rest)

    cond do
      references == [] ->
        :unresolved

      not Enum.all?(references, &CommitReferences.same_repository?/1) ->
        :unresolved

      true ->
        numbers = Enum.map(references, & &1.number)

        if Enum.all?(numbers, &Map.has_key?(states, &1)) do
          {:ok, Enum.all?(numbers, &(Map.get(states, &1) == "closed"))}
        else
          :unresolved
        end
    end
  end

  # `X` and `x` both mean checked. An item already in the right state keeps the
  # character the author typed, so rendering never rewrites a body for casing
  # alone.
  defp checked?(" "), do: false
  defp checked?(_mark), do: true

  defp mark(true), do: "x"
  defp mark(false), do: " "
end
