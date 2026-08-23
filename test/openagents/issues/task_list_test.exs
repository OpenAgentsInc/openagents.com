defmodule OpenAgents.Issues.TaskListTest do
  @moduledoc """
  #12: what a task-list checkbox is allowed to say.

  `TaskList` is pure, so these are the whole contract of the rendering half:
  which lines count as task-list items, which references resolve, and the two
  properties the write path depends on — idempotence and a body that is left
  byte-identical when nothing needs to move.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Issues.TaskList

  doctest OpenAgents.Issues.TaskList

  @closed %{6 => "closed"}
  @open %{6 => "open"}

  describe "render" do
    test "checks an item whose issue closed" do
      assert TaskList.render("- [ ] #6 Read the schema", @closed) == "- [x] #6 Read the schema"
    end

    test "unchecks an item whose issue reopened" do
      assert TaskList.render("- [x] #6 Read the schema", @open) == "- [ ] #6 Read the schema"
    end

    test "accepts every task-list marker Markdown renders" do
      for marker <- ["-", "*", "+", "1.", "2)"] do
        assert TaskList.render("#{marker} [ ] #6", @closed) == "#{marker} [x] #6"
      end
    end

    test "keeps the indentation of a nested item" do
      assert TaskList.render("    - [ ] #6", @closed) == "    - [x] #6"
    end

    test "rewrites only the lines that need it" do
      body = """
      Delivery slice:

      - [ ] #6 Read the schema
      - [x] #6 Already checked
      Not a list item, #6.
      """

      assert TaskList.render(body, @closed) == """
             Delivery slice:

             - [x] #6 Read the schema
             - [x] #6 Already checked
             Not a list item, #6.
             """
    end

    test "is idempotent" do
      body = "- [ ] #6\n- [ ] #6 again\n"
      once = TaskList.render(body, @closed)

      assert TaskList.render(once, @closed) == once
      assert TaskList.render(once, @closed) == "- [x] #6\n- [x] #6 again\n"
    end

    test "returns the identical binary when nothing moves" do
      body = "- [x] #6\n\nSome prose about #6.\n"

      assert TaskList.render(body, @closed) === body
    end

    test "leaves an already-checked item spelled with a capital X alone" do
      assert TaskList.render("- [X] #6", @closed) == "- [X] #6"
    end

    test "leaves a mention outside a task-list item alone" do
      assert TaskList.render("Blocked on #6.", @closed) == "Blocked on #6."
      assert TaskList.render("- #6", @closed) == "- #6"
      assert TaskList.render("> - [ ] #6", @closed) == "> - [ ] #6"
    end

    test "leaves an item with no reference alone" do
      assert TaskList.render("- [ ] Write the runbook", @closed) == "- [ ] Write the runbook"
    end

    test "leaves an item naming another repository alone" do
      body = "- [ ] OpenAgentsInc/openagents.com#6"

      assert TaskList.render(body, @closed) == body
    end

    test "leaves an item that mixes this repository with another alone" do
      body = "- [ ] #6 and OpenAgentsInc/openagents#7"

      assert TaskList.render(body, %{6 => "closed", 7 => "closed"}) == body
    end

    test "leaves an item naming an issue this repository does not have alone" do
      assert TaskList.render("- [ ] #999", @closed) == "- [ ] #999"
    end

    test "checks an item naming several issues only once every one is closed" do
      body = "- [ ] #6 and #7"

      assert TaskList.render(body, %{6 => "closed", 7 => "open"}) == body
      assert TaskList.render(body, %{6 => "closed", 7 => "closed"}) == "- [x] #6 and #7"
    end

    test "needs a space after the checkbox, the way Markdown does" do
      assert TaskList.render("- [ ]#6", @closed) == "- [ ]#6"
    end

    test "preserves carriage returns" do
      assert TaskList.render("- [ ] #6\r\n- [ ] #6\r\n", @closed) == "- [x] #6\r\n- [x] #6\r\n"
    end

    test "is total" do
      assert TaskList.render(nil, @closed) == nil
      assert TaskList.render("- [ ] #6", nil) == "- [ ] #6"
      assert TaskList.render(:body, @closed) == :body
      assert TaskList.render(String.duplicate("- [ ] #6\n", 20_000), @closed) =~ "- [ ] #6"
    end
  end

  describe "numbers" do
    test "reads the numbers task-list items name" do
      assert TaskList.numbers("- [ ] #6\n- [x] #7\n") == [6, 7]
    end

    test "ignores a number outside a task-list item" do
      assert TaskList.numbers("Blocked on #6.") == []
    end

    test "ignores a number in another repository" do
      assert TaskList.numbers("- [ ] OpenAgentsInc/openagents.com#6") == []
    end

    test "deduplicates" do
      assert TaskList.numbers("- [ ] #6\n- [ ] #6\n") == [6]
    end

    test "is total" do
      assert TaskList.numbers(nil) == []
      assert TaskList.numbers(String.duplicate("- [ ] #6\n", 20_000)) == []
    end
  end
end
