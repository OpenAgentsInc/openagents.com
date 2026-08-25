defmodule OpenAgents.Threads.WekaExportTest do
  @moduledoc """
  Tests for `OpenAgents.Threads.WekaExport`.
  """

  use OpenAgents.DataCase, async: true

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Repo
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.WekaExport

  describe "export/2" do
    test "a ledger-visible thread exports a deterministic, content-free document" do
      user = github_user("weka-export-consent")
      {:ok, thread} = Threads.open(user, "Test objective", visibility: "ledger")

      fixed_dt = DateTime.from_naive!(~N[2026-08-24 12:00:00.000000], "Etc/UTC")
      thread = thread |> change(started_at: fixed_dt) |> Repo.update!()

      insert_event(thread, "turn.user", %{"content" => "secret user prompt"}, fixed_dt)

      insert_event(
        thread,
        "turn.assistant",
        %{"output" => long_text_with("confidential code")},
        fixed_dt
      )

      assert {:ok, doc} = WekaExport.export(thread, "fixed-salt")

      assert doc["format"] == "weka-trace-v1"
      assert doc["thread_id"] == thread.id
      assert doc["generation"] == thread.generation
      assert doc["visibility"] == "ledger"
      assert doc["started_at"] == DateTime.to_iso8601(fixed_dt)
      assert doc["completed_at"] == nil
      assert doc["event_count"] == 4

      json = Jason.encode!(doc)
      refute String.contains?(json, "secret user prompt")
      refute String.contains?(json, "confidential code")

      for event <- doc["events"] do
        assert is_binary(event["emitted_at"])
        assert is_integer(event["block_count"])
        assert is_list(event["blocks"])
        assert length(event["blocks"]) == event["block_count"]
      end

      user_event = Enum.find(doc["events"], &(&1["event_type"] == "turn.user"))
      assistant_event = Enum.find(doc["events"], &(&1["event_type"] == "turn.assistant"))

      assert user_event["role"] == "user"
      assert user_event["block_count"] == 1

      assert user_event["emitted_at"] ==
               DateTime.to_iso8601(DateTime.truncate(fixed_dt, :microsecond))

      assert assistant_event["role"] == "assistant"
      assert assistant_event["block_count"] == 3

      total = Enum.reduce(doc["events"], 0, &(&2 + &1["block_count"]))
      assert doc["total_blocks"] == total
    end

    test "a dark thread refuses export" do
      user = github_user("weka-export-dark")
      {:ok, thread} = Threads.open(user, "Dark work")

      assert WekaExport.export(thread) == {:error, :consent_required}
      assert WekaExport.export(thread.id) == {:error, :consent_required}
    end

    test "an unknown or invalid thread id refuses export" do
      assert WekaExport.export(Ecto.UUID.generate()) == {:error, :thread_not_found}
      assert WekaExport.export("not-a-uuid") == {:error, :thread_not_found}
    end

    test "the same thread and salt export to a byte-identical document" do
      user = github_user("weka-export-repro")
      {:ok, thread} = Threads.open(user, "Repro", visibility: "ledger")
      insert_event(thread, "turn.user", %{"content" => "hello"}, DateTime.utc_now())

      salt = "same-salt"
      assert WekaExport.export(thread, salt) == WekaExport.export(thread, salt)
    end

    test "different salts produce different block hashes" do
      user = github_user("weka-export-salt")
      {:ok, thread} = Threads.open(user, "Salt", visibility: "ledger")
      insert_event(thread, "turn.user", %{"content" => "salted"}, DateTime.utc_now())

      {:ok, doc1} = WekaExport.export(thread, "salt-a")
      {:ok, doc2} = WekaExport.export(thread, "salt-b")

      blocks1 = doc1 |> Map.get("events") |> Enum.flat_map(& &1["blocks"])
      blocks2 = doc2 |> Map.get("events") |> Enum.flat_map(& &1["blocks"])

      refute blocks1 == blocks2
    end

    test "multi-turn context grows and block hashes chain" do
      user = github_user("weka-export-chain")
      {:ok, thread} = Threads.open(user, "Chain", visibility: "ledger")

      fixed_dt = DateTime.from_naive!(~N[2026-08-24 12:00:00.000000], "Etc/UTC")
      insert_event(thread, "turn.user", %{"content" => "word"}, fixed_dt)
      insert_event(thread, "turn.assistant", %{"output" => long_text_with("end")}, fixed_dt)

      assert {:ok, doc} = WekaExport.export(thread, "chain-salt")

      user_event = Enum.find(doc["events"], &(&1["event_type"] == "turn.user"))
      assistant_event = Enum.find(doc["events"], &(&1["event_type"] == "turn.assistant"))

      assert user_event["block_count"] == 1
      assert assistant_event["block_count"] == 3

      all_blocks = doc["events"] |> Enum.flat_map(& &1["blocks"])
      assert length(all_blocks) == length(Enum.uniq(all_blocks))
      assert doc["total_blocks"] == length(all_blocks)
    end
  end

  defp insert_event(thread, event_type, payload, emitted_at) do
    %Event{}
    |> Event.changeset(%{
      thread_id: thread.id,
      event_type: event_type,
      payload: payload,
      emitted_at: emitted_at
    })
    |> Repo.insert!()
  end

  defp long_text_with(suffix) do
    words = List.duplicate("word", 130) ++ [suffix]
    Enum.join(words, " ")
  end
end
