defmodule OpenAgents.Computer.AcpTranscriptTest do
  use ExUnit.Case, async: true
  @moduletag :skip

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

  defp frame(kind, fields) do
    @rs <> Enum.join([kind | fields], @us) <> "\n"
  end

  defp b64(text), do: Base.encode64(text)
end
