defmodule OpenAgents.Threads.WekaExportTest do
  @moduledoc """
  The proof behind `OpenAgents.Threads.WekaExport` and the export half of
  THREAD-002.

  Two claims carry the weight. The first is the consent gate: a thread its
  owner left `dark` — and a `dark` child of a consenting parent — contributes
  nothing to a trace or a corpus, not a request, not a block count, not a
  token. The second is fidelity: the exported block ids carry the source
  session's prefix structure, so prefix reuse measured on the anonymized trace
  is the same number as prefix reuse measured on the raw transcript. Both are
  falsifiable — an exporter that chunked per event, salted per request, or
  copied text through would fail one of them.
  """

  use OpenAgents.DataCase, async: true

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Repo
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.WekaExport

  @block 64
  @base ~U[2026-08-25 10:00:00.000000Z]

  describe "export/2 — the WEKA v1 document" do
    test "a consenting thread exports a replayable weka trace" do
      thread = coding_session("weka-shape")

      assert {:ok, trace} = WekaExport.export(thread)

      assert trace["id"] == thread.id
      assert trace["block_size"] == @block
      assert trace["hash_id_scope"] == "local"
      assert is_list(trace["models"])
      assert thread.model in trace["models"]

      requests = trace["requests"]
      assert length(requests) == 3

      for request <- requests do
        assert request["type"] == "n"
        assert is_binary(request["model"])
        assert is_integer(request["in"]) and request["in"] >= 0
        assert is_integer(request["out"]) and request["out"] > 0
        assert is_list(request["hash_ids"])
        assert Enum.all?(request["hash_ids"], &is_integer/1)
        assert is_float(request["t"]) and request["t"] >= 0.0
        assert is_float(request["api_time"]) and request["api_time"] > 0.0
      end

      # The hashed prompt is whole blocks, exactly as the reference converter
      # emits it, so `in` is what the replayer will actually send.
      for request <- requests, request["hash_ids"] != [] do
        assert request["in"] == length(request["hash_ids"]) * @block
      end

      # The first call has nothing to wait for; every later one records the gap.
      [first | rest] = requests
      refute Map.has_key?(first, "think_time")
      assert Enum.all?(rest, &(&1["think_time"] >= 0.0))
    end

    test "no transcript text survives the export" do
      thread = coding_session("weka-content")

      assert {:ok, trace} = WekaExport.export(thread)

      encoded = Jason.encode!(trace)

      for marker <- ~w(zqu1 zqr1 zqt1 zqa1 zqobj1) do
        refute String.contains?(encoded, marker),
               "#{marker} reached the exported trace"
      end
    end

    test "the same thread exports byte for byte" do
      thread = coding_session("weka-repro")

      assert {:ok, first} = WekaExport.export(thread, salt: "pinned")
      assert {:ok, second} = WekaExport.export(thread, salt: "pinned")

      assert Jason.encode!(first) == Jason.encode!(second)
    end

    test "an unknown or malformed thread id refuses" do
      assert WekaExport.export(Ecto.UUID.generate()) == {:error, :thread_not_found}
      assert WekaExport.export("not-a-uuid") == {:error, :thread_not_found}
    end
  end

  describe "export/2 — the consent gate" do
    test "a dark thread refuses, by struct and by id" do
      user = github_user("weka-dark")
      {:ok, thread} = Threads.open(user, "Dark work")

      assert WekaExport.export(thread) == {:error, :consent_required}
      assert WekaExport.export(thread.id) == {:error, :consent_required}
    end

    test "a dark child of a consenting parent contributes nothing" do
      user = github_user("weka-dark-child")
      {:ok, parent} = Threads.open(user, "Parent objective", visibility: "ledger")

      {:ok, dark} =
        Threads.open(user, "zqdarkchild objective",
          parent_thread_id: parent.id,
          visibility: "dark"
        )

      insert_event(dark, "turn.user", %{"content" => words("darkuser", 200)})
      insert_event(dark, "turn.assistant", %{"output" => words("darkanswer", 200)})

      insert_event(parent, "turn.user", %{"content" => words("u", 200)})
      insert_event(parent, "turn.assistant", %{"output" => words("a", 120)})
      restamp(parent)
      restamp(dark)

      assert {:ok, trace} = WekaExport.export(parent)

      refute Enum.any?(trace["requests"], &(&1["type"] == "subagent"))

      encoded = Jason.encode!(trace)
      refute String.contains?(encoded, "zqdarkuser1")
      refute String.contains?(encoded, "zqdarkanswer1")
      refute String.contains?(encoded, dark.id)
    end

    test "a consenting child becomes a sub-agent entry" do
      user = github_user("weka-child")
      {:ok, parent} = Threads.open(user, "Parent objective", visibility: "ledger")

      {:ok, child} =
        Threads.open(user, "Child objective",
          parent_thread_id: parent.id,
          visibility: "ledger"
        )

      insert_event(child, "turn.user", %{"content" => words("cu", 200)})
      insert_event(child, "tool.ran", %{"content" => words("ct", 150)})
      insert_event(child, "turn.assistant", %{"output" => words("ca", 90)})

      insert_event(parent, "turn.user", %{"content" => words("u", 200)})
      insert_event(parent, "turn.assistant", %{"output" => words("a", 120)})
      restamp(parent)
      restamp(child)

      assert {:ok, trace} = WekaExport.export(parent)

      assert entry = Enum.find(trace["requests"], &(&1["type"] == "subagent"))
      assert entry["subagent_type"] == "child_thread"
      assert entry["status"] == "running"
      assert entry["tool_use_count"] == 1
      assert entry["models"] == [child.model]
      assert length(entry["requests"]) == 2
      assert entry["total_tokens"] > 0
      assert entry["duration_ms"] >= 0
      assert Enum.all?(entry["requests"], &(&1["type"] == "n"))
      assert child.model in trace["models"]
    end
  end

  describe "export/2 — block identity" do
    test "each call's blocks extend the call before it" do
      thread = coding_session("weka-prefix")

      assert {:ok, trace} = WekaExport.export(thread)

      trace["requests"]
      |> Enum.map(& &1["hash_ids"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [earlier, later] ->
        assert length(later) > length(earlier)
        assert Enum.take(later, length(earlier)) == earlier
      end)
    end

    test "the same block text at a different context position gets a different id" do
      user = github_user("weka-chain")
      {:ok, thread} = Threads.open(user, "Chained", visibility: "ledger")

      repeated = words("rep", @block)

      insert_event(thread, "turn.user", %{"content" => repeated})
      insert_event(thread, "turn.assistant", %{"output" => words("pad", @block)})
      insert_event(thread, "turn.user", %{"content" => repeated})
      insert_event(thread, "turn.assistant", %{"output" => words("tail", 8)})
      restamp(thread)

      assert {:ok, trace} = WekaExport.export(thread)

      ids = trace["requests"] |> List.last() |> Map.fetch!("hash_ids")

      # The identical 64 tokens appear twice in one context. Chained hashing
      # means the second copy hashes over a different prefix, so the block that
      # would hit a warm KV cache and the block that would not are told apart.
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "prefix_reuse/1" do
    test "the anonymized trace reports the source session's prefix reuse" do
      thread = coding_session("weka-reuse")

      assert {:ok, trace} = WekaExport.export(thread)

      measured = WekaExport.prefix_reuse(trace)
      source = source_prefix_reuse(thread)

      assert measured["blocks"] == source.blocks
      assert measured["reused_blocks"] == source.reused
      assert measured["requests"] == 3
      assert source.blocks > 0
      assert source.reused > 0
      assert measured["rate"] == source.reused / source.blocks

      # Contexts only grow, so every block of every call but the last is
      # carried into the call after it. That identity is what a serving stack's
      # KV cache would see, and it is derived here rather than assumed.
      last = trace["requests"] |> List.last() |> Map.fetch!("hash_ids")
      assert measured["reused_blocks"] == measured["blocks"] - length(last)
    end
  end

  describe "corpus/2" do
    test "a corpus is reproducible from its recorded thread-id set and revision" do
      first = coding_session("weka-corpus-a")
      second = coding_session("weka-corpus-b")

      assert {:ok, corpus} =
               WekaExport.corpus([first.id, second.id], salt: "pinned", revision: "rev-1")

      assert corpus["format"] == "openagents-weka-corpus-v1"
      assert corpus["block_size"] == @block
      assert corpus["hash_id_scope"] == "local"
      assert corpus["code_revision"] == "rev-1"
      assert corpus["requested_thread_ids"] == [first.id, second.id]
      assert corpus["included_thread_ids"] == [first.id, second.id]
      assert corpus["refused"] == []
      assert length(corpus["traces"]) == 2
      assert corpus["prefix_reuse"]["blocks"] > 0

      assert {:ok, again} =
               WekaExport.corpus(corpus["requested_thread_ids"],
                 salt: "pinned",
                 revision: corpus["code_revision"]
               )

      assert Jason.encode!(again) == Jason.encode!(corpus)
    end

    test "a corpus records its revision without being told one" do
      thread = coding_session("weka-corpus-rev")

      assert {:ok, corpus} = WekaExport.corpus([thread.id])
      assert is_binary(corpus["code_revision"])
      assert corpus["code_revision"] != ""
    end

    test "a named thread that has not consented is refused, not exported" do
      consenting = coding_session("weka-corpus-open")

      user = github_user("weka-corpus-dark")
      {:ok, dark} = Threads.open(user, "zqdarkobjective")
      insert_event(dark, "turn.user", %{"content" => words("darkuser", 200)})
      insert_event(dark, "turn.assistant", %{"output" => words("darkanswer", 200)})
      restamp(dark)

      missing = Ecto.UUID.generate()

      assert {:ok, corpus} = WekaExport.corpus([consenting.id, dark.id, missing])

      assert corpus["included_thread_ids"] == [consenting.id]

      assert corpus["refused"] == [
               %{"thread_id" => dark.id, "reason" => "consent_required"},
               %{"thread_id" => missing, "reason" => "thread_not_found"}
             ]

      encoded = Jason.encode!(corpus)
      refute String.contains?(encoded, "zqdarkuser1")
      refute String.contains?(encoded, "zqdarkanswer1")
      assert Enum.all?(corpus["traces"], &(&1["id"] != dark.id))
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  # One coder-shaped session: a question, the model's reasoning, a tool call,
  # more reasoning, an answer, a follow-up question, a second answer. Three
  # model calls, each carrying everything recorded before it.
  defp coding_session(handle) do
    user = github_user(handle)
    {:ok, thread} = Threads.open(user, "Objective " <> words("obj", 10), visibility: "ledger")

    insert_event(thread, "turn.user", %{"content" => words("u", 200)})
    insert_event(thread, "turn.reasoning", %{"content" => words("r", 100)})
    insert_event(thread, "tool.ran", %{"content" => words("t", 150)})
    insert_event(thread, "turn.reasoning", %{"content" => words("r2", 80)})
    insert_event(thread, "turn.assistant", %{"output" => words("a", 120)})
    insert_event(thread, "turn.user", %{"content" => words("u2", 90)})
    insert_event(thread, "turn.assistant", %{"output" => words("a2", 70)})

    restamp(thread)
  end

  defp insert_event(thread, event_type, payload) do
    %Event{}
    |> Event.changeset(%{
      thread_id: thread.id,
      event_type: event_type,
      payload: payload,
      emitted_at: @base
    })
    |> Repo.insert!()
  end

  # Every event one second apart from a fixed start, so `t`, `api_time`, and
  # `think_time` are facts about the fixture rather than about the clock.
  defp restamp(thread) do
    thread.id
    |> events()
    |> Enum.with_index()
    |> Enum.each(fn {event, index} ->
      event
      |> change(emitted_at: DateTime.add(@base, index + 1, :second))
      |> Repo.update!()
    end)

    thread |> change(started_at: @base) |> Repo.update!()
  end

  defp events(thread_id) do
    Repo.all(
      from(event in Event, where: event.thread_id == ^thread_id, order_by: [asc: event.id])
    )
  end

  defp words(prefix, count) do
    Enum.map_join(1..count, " ", &"zq#{prefix}#{&1}")
  end

  # ── an independent reading of the source ───────────────────────────────────

  # Rebuild each model call's prompt from the raw transcript, cut it into
  # 64-token blocks of plain text, and count the leading blocks each call
  # shares with the call before it. No hashing and no id remapping: if the
  # exported hash ids carry the source's block structure, this number and
  # `prefix_reuse/1`'s number are the same one.
  defp source_prefix_reuse(thread) do
    {prompts, _context, _run} =
      thread.id
      |> events()
      |> Enum.reduce({[], [], []}, fn event, {prompts, context, run} ->
        tokens = String.split(source_text(event.payload), ~r/\s+/, trim: true)

        cond do
          terminating?(event.event_type) ->
            {[context | prompts], context ++ run ++ tokens, []}

          model_authored?(event.event_type) ->
            {prompts, context, run ++ tokens}

          true ->
            {prompts, context ++ tokens, run}
        end
      end)

    prompts
    |> Enum.reverse()
    |> Enum.map(&Enum.chunk_every(&1, @block, @block, :discard))
    |> Enum.reduce({0, 0, nil}, fn blocks, {reused, total, previous} ->
      shared = if previous, do: common_prefix(previous, blocks), else: 0
      {reused + shared, total + length(blocks), blocks}
    end)
    |> then(fn {reused, total, _previous} -> %{reused: reused, blocks: total} end)
  end

  defp common_prefix(earlier, later) do
    earlier |> Enum.zip(later) |> Enum.take_while(fn {a, b} -> a == b end) |> length()
  end

  defp source_text(payload) do
    case payload["content"] || payload["text"] || payload["message"] || payload["output"] do
      value when is_binary(value) -> value
      nil -> Jason.encode!(payload)
      value -> Jason.encode!(value)
    end
  end

  defp terminating?("turn.assistant"), do: true
  defp terminating?("tool." <> _rest), do: true
  defp terminating?(_type), do: false

  defp model_authored?("turn.reasoning"), do: true
  defp model_authored?(type), do: terminating?(type)
end
