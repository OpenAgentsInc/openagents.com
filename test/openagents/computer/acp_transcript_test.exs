defmodule OpenAgents.Computer.AcpTranscriptTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Computer.AcpTranscript

  @rs <<30>>
  @us <<31>>

  test "plain text with no frames is unchanged" do
    assert AcpTranscript.decode("partial investigation notes before the ceiling") ==
             "partial investigation notes before the ceiling"
  end

  test "empty and non-binaries decode to an empty string" do
    assert AcpTranscript.decode("") == ""
    assert AcpTranscript.decode(nil) == ""
    assert AcpTranscript.decode(%{}) == ""
  end

  test "decodes T frames into kind/title/detail without tool ids or raw base64" do
    stream =
      "I'll start by inspecting the repo.\n" <>
        frame("T", ["toolu_011zKMF7gb9qrjngWDUhAtUb", "0", "execute", b64("Terminal"), ""]) <>
        frame(
          "T",
          [
            "toolu_011zKMF7gb9qrjngWDUhAtUb",
            "1",
            "execute",
            b64("Terminal"),
            b64("On branch main\nnothing to commit")
          ]
        )

    report = AcpTranscript.decode(stream)

    assert report =~ "I'll start by inspecting the repo."
    assert report =~ "Terminal"
    assert report =~ "On branch main"
    assert report =~ "nothing to commit"
    refute report =~ "toolu_"
    refute report =~ "VGVybWluYWw"
    refute report =~ @rs
    refute report =~ @us
  end

  test "failed tools are marked and permission notes are readable" do
    stream =
      frame("T", [
        "toolu_01fail",
        "2",
        "edit",
        b64("chat_live.ex"),
        b64("User refused permission")
      ]) <>
        frame("N", [b64("Permission denied: grep -r Submit"), "warn"])

    report = AcpTranscript.decode(stream)

    assert report =~ "Edit: chat_live.ex (failed)"
    assert report =~ "User refused permission"
    assert report =~ "Warning: Permission denied: grep -r Submit"
    refute report =~ "toolu_01fail"
  end

  test "a tool that never completes is listed as in progress" do
    stream =
      "searching\n" <>
        frame("T", ["toolu_01open", "0", "read", b64("chat_live.ex"), ""])

    report = AcpTranscript.decode(stream)

    assert report =~ "searching"
    assert report =~ "Read: chat_live.ex (in progress)"
    refute report =~ "toolu_01open"
  end

  test "an incomplete trailing frame (no newline) is still parsed" do
    stream =
      "prose" <>
        @rs <> Enum.join(["T", "toolu_01x", "1", "search", b64("Submit"), b64("3 hits")], @us)

    report = AcpTranscript.decode(stream)

    assert report =~ "prose"
    assert report =~ "Search: Submit"
    assert report =~ "3 hits"
  end

  test "summarize keeps the prose and failures, and counts the rest" do
    stream =
      "I read the failing test and fixed the selector.\n" <>
        frame("T", ["toolu_01run", "1", "execute", b64("git status"), b64("On branch main")]) <>
        frame("T", ["toolu_02read", "1", "read", b64("chat_live.ex"), b64("defmodule")]) <>
        frame("T", ["toolu_03edit", "2", "edit", b64("chat_live.ex"), b64("User refused")]) <>
        frame("N", [b64("Permission denied: Edit"), "warn"])

    assert {text, 3} = AcpTranscript.summarize(stream)

    # What explains the outcome stays: the agent's words, its notes, the failure.
    assert text =~ "I read the failing test and fixed the selector."
    assert text =~ "Edit: chat_live.ex (failed)"
    assert text =~ "Warning: Permission denied: Edit"

    # The tool-by-tool log does not.
    refute text =~ "git status"
    refute text =~ "On branch main"
    refute text =~ "Read: chat_live.ex"
  end

  test "summarize counts a tool that never finished, and empties safely" do
    stream = frame("T", ["toolu_01open", "0", "read", b64("chat_live.ex"), ""])

    assert {"", 1} = AcpTranscript.summarize(stream)
    assert AcpTranscript.summarize("") == {"", 0}
    assert AcpTranscript.summarize(nil) == {"", 0}
  end

  defp frame(kind, fields) do
    @rs <> Enum.join([kind | fields], @us) <> "\n"
  end

  defp b64(text), do: Base.encode64(text)
end
