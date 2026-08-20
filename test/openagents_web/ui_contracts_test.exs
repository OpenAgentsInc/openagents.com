defmodule OpenAgentsWeb.UIContractsTest do
  @moduledoc """
  Contracts that hold across every template, checked by reading the source.

  These catch a specific class of defect: a control that renders, looks
  finished, and does nothing. A behavioural test cannot see it. `render_submit`
  submits the form without touching the button; `render_click` pushes the event
  the element declares whether or not a browser could ever reach it; a hook that
  never mounts leaves the markup identical. In every case the server path is
  exercised and correct while the thing a person clicks is dead.

  Seven such defects shipped before the first of these existed (see
  `OpenAgentsWeb.FormSubmitButtonsTest`). The rules below are the ones that
  would have caught them, plus the neighbouring cases in the same family.

  A `phx-hook` without an id belongs to this family and is deliberately not
  checked here: LiveView's own compiler raises on it, and a rule that repeats
  the compiler adds noise without adding protection.

  Each rule is deliberately narrow. A rule that fires on correct markup gets
  suppressed rather than fixed, and then it protects nothing.
  """

  use ExUnit.Case, async: true

  @interactive ~w(button a input select textarea summary)

  describe "controls that would be inert" do
    test "every .link has somewhere to go" do
      # A link that spreads a global is excluded: its destination arrives in
      # `@rest`, so the call site decides whether there is one. Both such links
      # in the component library also guard themselves with an `:if` on exactly
      # those keys, which is the honest way to write it.
      assert_no_offenders(
        fn name, attrs, _body ->
          name == ".link" and
            not Enum.any?(~w(navigate patch href), &has?(attrs, &1)) and
            not String.contains?(attrs, "{@rest}")
        end,
        "are links with no navigate, patch, or href"
      )
    end

    test "no popover trigger names a target that does not exist in its template" do
      assert_no_dangling("popovertarget")
    end
  end

  describe "controls that would be unreachable" do
    test "a phx-click on a non-interactive element is reachable another way" do
      # A div or td that handles a click is not focusable and announces
      # nothing, so it is mouse-only. It is fine when the element declares a
      # role and takes focus, or when it holds a real control that does the
      # same thing -- clicking the surrounding region is then a convenience.
      assert_no_offenders(
        fn name, attrs, body ->
          name in ~w(div span li td tr section article p dl dd) and
            has?(attrs, "phx-click") and
            not (has?(attrs, "role") and has?(attrs, "tabindex")) and
            not contains_control?(body)
        end,
        "handle a click but cannot be reached by keyboard"
      )
    end

    test "no aria reference points at an id that is not in the same template" do
      for attribute <- ~w(aria-controls aria-labelledby aria-describedby) do
        assert_no_dangling(attribute)
      end
    end
  end

  describe "identity" do
    test "no template declares the same literal id twice" do
      offenders =
        for path <- templates(),
            source = File.read!(path),
            {id, count} <-
              Enum.frequencies(
                Regex.scan(~r/\bid="([^"{}]+)"/, source, capture: :all_but_first)
                |> List.flatten()
              ),
            count > 1,
            do: {path, id}

      assert offenders == [], """
      These templates declare the same id more than once. Duplicate ids break
      LiveView's DOM patching and every aria reference that names them:

      #{format(offenders)}
      """
    end
  end

  # ── scanning ──────────────────────────────────────────────────────────────

  defp assert_no_offenders(predicate, description) do
    offenders =
      for path <- templates(),
          {name, attrs, body, line} <- tags(File.read!(path)),
          predicate.(name, attrs, body),
          do: {path, line, name}

    assert offenders == [], """
    These elements #{description}:

    #{format(offenders)}
    """
  end

  defp assert_no_dangling(attribute) do
    offenders =
      for path <- templates(),
          source = File.read!(path),
          ids = literal_ids(source),
          {_name, attrs, _body, line} <- tags(source),
          reference <- references(attrs, attribute),
          reference not in ids,
          do: {path, line, "#{attribute}=#{reference}"}

    assert offenders == [], """
    These `#{attribute}` values name an id that does not appear in the same
    template, so the relationship they declare does not exist:

    #{format(offenders)}
    """
  end

  defp templates do
    Path.wildcard("lib/openagents_web/**/*.ex") ++ Path.wildcard("lib/openagents_web/**/*.heex")
  end

  defp literal_ids(source) do
    ~r/\bid="([^"{}]+)"/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  # Only literal references are checked. An interpolated one is computed, and
  # guessing at what it computes to would produce noise rather than findings.
  defp references(attrs, attribute) do
    case Regex.run(~r/#{attribute}="([^"{}]+)"/, attrs, capture: :all_but_first) do
      [value] -> String.split(value)
      nil -> []
    end
  end

  defp has?(attrs, attribute), do: Regex.match?(~r/(?<![-\w])#{Regex.escape(attribute)}=/, attrs)

  defp contains_control?(body) do
    Enum.any?(@interactive, &String.contains?(body, "<#{&1}")) or
      String.contains?(body, "<.button") or String.contains?(body, "<UI.button") or
      String.contains?(body, "<.link") or String.contains?(body, "<UI.")
  end

  # HEEx attributes hold `{...}` expressions that themselves hold braces and
  # quotes, so the tag is walked rather than matched: a regex stops at the
  # first `>` inside an expression and silently truncates the attributes,
  # which reads as an element that is missing whatever came after it.
  defp tags(source) do
    do_tags(source, 0, [])
  end

  defp do_tags(source, from, acc) do
    case :binary.match(source, "<", scope: {from, byte_size(source) - from}) do
      :nomatch ->
        Enum.reverse(acc)

      {start, _length} ->
        case Regex.run(
               ~r/^<([A-Za-z.][\w.:]*)/,
               binary_part(source, start, min(64, byte_size(source) - start)),
               return: :index
             ) do
          nil ->
            do_tags(source, start + 1, acc)

          [{_, _}, {name_start, name_length}] ->
            name = binary_part(source, start + name_start, name_length)
            attrs_start = start + name_start + name_length
            attrs_end = close_of(source, attrs_start, 0, nil)
            attrs = binary_part(source, attrs_start, attrs_end - attrs_start)
            line = count_lines(source, start)
            body = body_of(source, name, attrs_end)
            do_tags(source, attrs_end + 1, [{name, attrs, body, line} | acc])
        end
    end
  end

  defp close_of(source, index, depth, quote_char) when index < byte_size(source) do
    char = binary_part(source, index, 1)

    cond do
      quote_char && char == quote_char -> close_of(source, index + 1, depth, nil)
      quote_char -> close_of(source, index + 1, depth, quote_char)
      char in ["\"", "'"] -> close_of(source, index + 1, depth, char)
      char == "{" -> close_of(source, index + 1, depth + 1, nil)
      char == "}" -> close_of(source, index + 1, depth - 1, nil)
      char == ">" and depth == 0 -> index
      true -> close_of(source, index + 1, depth, nil)
    end
  end

  defp close_of(source, _index, _depth, _quote), do: byte_size(source)

  # The element's own body, found by counting nested opens of the same name.
  # Taking a fixed window after the tag instead means the scan sees whatever
  # follows the element in the file, which excuses every element in it.
  defp body_of(source, name, from) do
    open = "<" <> name
    close = "</" <> name <> ">"
    scan_body(source, open, close, from, from, 1)
  end

  defp scan_body(source, open, close, body_start, index, depth) do
    next_open = :binary.match(source, open, scope: {index, byte_size(source) - index})
    next_close = :binary.match(source, close, scope: {index, byte_size(source) - index})

    case {next_open, next_close} do
      {_, :nomatch} ->
        ""

      {:nomatch, {c, _len}} when depth == 1 ->
        binary_part(source, body_start, c - body_start)

      {:nomatch, {c, len}} ->
        scan_body(source, open, close, body_start, c + len, depth - 1)

      {{o, olen}, {c, _clen}} when o < c ->
        scan_body(source, open, close, body_start, o + olen, depth + 1)

      {_, {c, _clen}} when depth == 1 ->
        binary_part(source, body_start, c - body_start)

      {_, {c, clen}} ->
        scan_body(source, open, close, body_start, c + clen, depth - 1)
    end
  end

  defp count_lines(source, upto) do
    source |> binary_part(0, upto) |> :binary.matches("\n") |> length() |> Kernel.+(1)
  end

  defp format(offenders) do
    Enum.map_join(offenders, "\n", fn
      {path, line, detail} -> "  #{path}:#{line}  #{detail}"
      {path, detail} -> "  #{path}  #{detail}"
    end)
  end
end
