defmodule OpenAgents.Memory.Evaluation.Runner do
  @moduledoc "Executes synthetic recall fixtures against PostgreSQL without retaining eval data."

  alias OpenAgents.{Conversations, Repo}
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Memory.Evaluation.{Corpus, Report}
  alias OpenAgents.Memory.LexicalRecall

  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    corpus = Corpus.load!()

    case Repo.transaction(fn -> Repo.rollback(run_corpus(corpus)) end) do
      {:error, %{"schema" => "sarah.recall.eval_report.v1"} = report} -> {:ok, report}
      {:error, reason} -> {:error, reason}
      {:ok, _unexpected} -> {:error, :evaluation_transaction_not_rolled_back}
    end
  end

  defp run_corpus(corpus) do
    results = Enum.map(corpus["cases"], &run_case/1)
    Report.build(corpus, results)
  end

  defp run_case(evaluation_case) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    {:ok, conversation} = Conversations.ensure_conversation("recall-eval-#{suffix}")
    {:ok, foreign} = Conversations.ensure_conversation("recall-eval-foreign-#{suffix}")
    now = DateTime.utc_now()

    current_index = insert_messages(conversation.id, evaluation_case["messages"], now)
    foreign_index = insert_messages(foreign.id, evaluation_case["foreign_messages"], now)
    insert_fillers(conversation.id, evaluation_case["filler_count"], now)

    {:ok, snapshot_ref} = LexicalRecall.capture_ref(Repo, conversation.id, Ecto.UUID.generate())
    {:ok, snapshot} = LexicalRecall.load_snapshot(conversation, snapshot_ref)

    late_index = maybe_insert_late_match(conversation.id, evaluation_case, snapshot)
    label_index = Map.merge(current_index, late_index)
    source_to_label = Map.new(label_index, fn {label, source_ref} -> {source_ref, label} end)
    foreign_refs = foreign_index |> Map.values() |> MapSet.new()

    {:ok, page_10} =
      LexicalRecall.search_page(conversation, snapshot, evaluation_case["query"], first: 10)

    {:ok, requested_page} =
      LexicalRecall.search_page(
        conversation,
        snapshot,
        evaluation_case["query"],
        first: evaluation_case["first"]
      )

    refs_10 = Enum.map(page_10.matches, & &1.source_ref)

    retrieved_labels = Enum.map(refs_10, &Map.get(source_to_label, &1, "unexpected"))
    expected_labels = MapSet.new(evaluation_case["relevant_labels"])
    empty = refs_10 == []
    foreign_ref_count = Enum.count(refs_10, &MapSet.member?(foreign_refs, &1))
    excerpt_truncated = Enum.any?(page_10.matches, & &1.truncated)

    late_match_excluded =
      Enum.all?(Map.values(late_index), fn source_ref -> source_ref not in refs_10 end)

    provider_window_excluded =
      conversation.id
      |> Conversations.provider_messages()
      |> Enum.all?(&(not String.contains?(&1.content, evaluation_case["query"])))

    window_expectation_met =
      evaluation_case["journey"] != "outside_provider_window" or provider_window_excluded

    case_passed =
      empty == evaluation_case["expect_empty"] and
        requested_page.truncated == evaluation_case["expect_truncated"] and
        excerpt_truncated == evaluation_case["expect_excerpt_truncated"] and
        MapSet.subset?(MapSet.new(retrieved_labels), expected_labels) and
        MapSet.subset?(expected_labels, MapSet.new(retrieved_labels)) and
        foreign_ref_count == 0 and late_match_excluded and window_expectation_met

    %{
      "case_id" => evaluation_case["id"],
      "retrieved_at_3" =>
        refs_10 |> Enum.take(3) |> Enum.map(&Map.get(source_to_label, &1, "unexpected")),
      "retrieved_at_10" => retrieved_labels,
      "empty" => empty,
      "requested_page_truncated" => requested_page.truncated,
      "excerpt_truncated" => excerpt_truncated,
      "foreign_ref_count" => foreign_ref_count,
      "late_match_excluded" => late_match_excluded,
      "provider_window_excluded" => provider_window_excluded,
      "case_passed" => case_passed
    }
  end

  defp insert_messages(conversation_id, messages, now) do
    Map.new(messages, fn message ->
      timestamp = DateTime.add(now, -message["age_seconds"], :second)

      inserted =
        Repo.insert!(%Message{
          conversation_id: conversation_id,
          role: message["role"],
          content: message["content"],
          status: message["status"],
          inserted_at: timestamp,
          updated_at: timestamp
        })

      {message["label"], "message:#{inserted.id}"}
    end)
  end

  defp insert_fillers(_conversation_id, 0, _now), do: :ok

  defp insert_fillers(conversation_id, count, now) do
    for index <- 1..count do
      timestamp = DateTime.add(now, -(count - index + 1), :second)

      Repo.insert!(%Message{
        conversation_id: conversation_id,
        role: if(rem(index, 2) == 0, do: "user", else: "assistant"),
        content: "synthetic provider-window filler #{index}",
        status: "complete",
        inserted_at: timestamp,
        updated_at: timestamp
      })
    end

    :ok
  end

  defp maybe_insert_late_match(
         _conversation_id,
         %{"insert_match_after_snapshot" => false},
         _snapshot
       ),
       do: %{}

  defp maybe_insert_late_match(conversation_id, evaluation_case, snapshot) do
    timestamp = DateTime.add(snapshot.inserted_at, 1, :second)

    inserted =
      Repo.insert!(%Message{
        conversation_id: conversation_id,
        role: "user",
        content: "late frozen-boundary #{evaluation_case["query"]}",
        status: "complete",
        inserted_at: timestamp,
        updated_at: timestamp
      })

    %{"late_match" => "message:#{inserted.id}"}
  end
end
