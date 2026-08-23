defmodule OpenAgents.Forge.CommitReferencesTest do
  @moduledoc """
  #130: reading closing references out of a commit message. The reader runs on
  the push path, so every case here is also a statement that it returns a list
  rather than raising.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Forge.CommitReferences

  describe "the inline GitHub form" do
    test "reads a closing reference from the commit body" do
      assert CommitReferences.closing_numbers("Delegate to a Box\n\nCloses #126") == [126]
    end

    test "reads it from the subject line" do
      assert CommitReferences.closing_numbers("Closes #126") == [126]
    end

    test "treats Fixes and Resolves the same as Closes" do
      assert CommitReferences.closing_numbers("Body\n\nFixes #12") == [12]
      assert CommitReferences.closing_numbers("Body\n\nResolves #12") == [12]
    end

    test "accepts every tense of the keyword, in any case" do
      for verb <- ~w(close closes closed fix fixes fixed resolve resolves resolved) do
        assert CommitReferences.closing_numbers("Body\n\n#{verb} #9") == [9],
               "#{verb} did not read as a closing keyword"

        assert CommitReferences.closing_numbers("Body\n\n#{String.upcase(verb)} #9") == [9]
      end
    end

    test "reads a comma-separated list" do
      assert CommitReferences.closing_numbers("Body\n\nCloses #12, #13, #14") == [12, 13, 14]
    end

    test "reads a list joined with and" do
      assert CommitReferences.closing_numbers("Body\n\nFixes #7 and #8") == [7, 8]
    end

    test "reads several closing lines" do
      assert CommitReferences.closing_numbers("Body\n\nCloses #1\nFixes #2\nResolves #3") ==
               [1, 2, 3]
    end
  end

  describe "the trailer form" do
    test "reads a Closes trailer" do
      assert CommitReferences.closing_numbers("Body\n\nCloses: #126") == [126]
    end

    test "reads a trailer list" do
      assert CommitReferences.closing_numbers("Body\n\nFixes: #12, #13") == [12, 13]
    end
  end

  describe "what it refuses" do
    test "a message with no closing keyword closes nothing" do
      assert CommitReferences.closing_numbers("Fix the parser for #42") == []
      assert CommitReferences.closing_numbers("See #42 for context") == []
    end

    test "a keyword embedded in a longer word is not a keyword" do
      assert CommitReferences.closing_numbers("Enclosed #5 in the payload") == []
      assert CommitReferences.closing_numbers("Prefixes #5") == []
    end

    test "a cross-repository reference is read but not treated as local" do
      message = "Body\n\nCloses OpenAgentsInc/openagents.com#12"

      assert [reference] = CommitReferences.closing(message)
      assert reference.owner == "OpenAgentsInc"
      assert reference.repository == "openagents.com"
      assert reference.number == 12
      refute CommitReferences.same_repository?(reference)
      assert CommitReferences.closing_numbers(message) == []
    end

    test "issue zero and an out-of-range number are not references" do
      assert CommitReferences.closing_numbers("Closes #0") == []
      assert CommitReferences.closing_numbers("Closes #9999999999") == []
    end

    test "a truncated reference is not a reference" do
      assert CommitReferences.closing_numbers("Closes #") == []
      assert CommitReferences.closing_numbers("Closes") == []
      assert CommitReferences.closing_numbers("Closes #abc") == []
    end

    test "the same reference twice records once" do
      assert CommitReferences.closing_numbers("Closes #12\n\nCloses #12") == [12]
    end
  end

  describe "totality" do
    test "a non-binary message returns an empty list rather than raising" do
      for message <- [nil, 123, %{}, [], :closes, {1, 2}] do
        assert CommitReferences.closing(message) == []
        assert CommitReferences.all(message) == []
        assert CommitReferences.closing_numbers(message) == []
      end
    end

    test "invalid UTF-8 and stray punctuation return a list" do
      assert is_list(CommitReferences.closing(<<0xFF, 0xFE, "Closes #12">>))
      assert is_list(CommitReferences.closing("Closes ###12 ,,, #"))
    end

    test "a very long message is clamped rather than scanned forever" do
      message = String.duplicate("a #1 b\n", 20_000) <> "\nCloses #12"
      assert is_list(CommitReferences.closing_numbers(message))
    end

    test "no single commit records more references than the cap" do
      body = Enum.map_join(1..200, "\n", fn n -> "Closes ##{n}" end)
      assert length(CommitReferences.closing_numbers(body)) <= 32
    end
  end

  describe "all/1, which issue #12 consumes" do
    test "returns plain mentions alongside closing references" do
      references = CommitReferences.all("Closes #12\n\n- [ ] #13\n- [x] #14")

      assert Enum.map(references, & &1.number) == [12, 13, 14]
      assert Enum.map(references, & &1.closing?) == [true, false, false]
    end

    test "carries the verb that introduced a closing reference" do
      assert [%{verb: "fixes", closing?: true}] = CommitReferences.all("Fixes #12")
    end
  end
end
