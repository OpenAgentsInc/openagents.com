defmodule Mix.Tasks.Openagents.Weka.ExportTest do
  @moduledoc """
  The operator surface for the WEKA corpus. The consent gate is proven again
  here rather than only at `OpenAgents.Threads.WekaExport`, because this is the
  path a corpus actually leaves by, and a gate that holds in the context and
  not at the surface is not a gate.
  """

  use OpenAgents.DataCase

  import ExUnit.CaptureIO
  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Repo
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Event

  test "writes a corpus from a recorded id file and refuses a dark thread" do
    consenting = session("weka-task-open", "ledger")
    dark = session("weka-task-dark", "dark")

    directory = tmp_dir()
    set = Path.join(directory, "corpus-set.txt")
    out = Path.join(directory, "corpus.json")

    File.write!(set, """
    # the recorded thread-id set
    #{consenting.id}
    #{dark.id}
    """)

    output =
      capture_io(fn ->
        Mix.Tasks.Openagents.Weka.Export.run(["--threads", set, "--out", out])
      end)

    assert output =~ "1 trace(s)"
    assert output =~ "1 refused"
    assert output =~ "refused #{dark.id}: consent_required"

    corpus = out |> File.read!() |> Jason.decode!()

    assert corpus["requested_thread_ids"] == [consenting.id, dark.id]
    assert corpus["included_thread_ids"] == [consenting.id]
    assert corpus["refused"] == [%{"thread_id" => dark.id, "reason" => "consent_required"}]
    assert is_binary(corpus["code_revision"])

    refute String.contains?(File.read!(out), "zqdark")
  after
    Mix.Task.reenable("openagents.weka.export")
  end

  test "refuses to run without a thread-id set" do
    assert_raise Mix.Error, fn -> Mix.Tasks.Openagents.Weka.Export.run([]) end
  after
    Mix.Task.reenable("openagents.weka.export")
  end

  defp session(handle, visibility) do
    user = github_user(handle)
    marker = if visibility == "dark", do: "zqdark", else: "zqopen"
    {:ok, thread} = Threads.open(user, "Objective", visibility: visibility)

    insert_event(thread, "turn.user", %{"content" => words(marker <> "u", 200)})
    insert_event(thread, "turn.assistant", %{"output" => words(marker <> "a", 120)})

    thread
  end

  defp insert_event(thread, event_type, payload) do
    %Event{}
    |> Event.changeset(%{
      thread_id: thread.id,
      event_type: event_type,
      payload: payload,
      emitted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp words(prefix, count), do: Enum.map_join(1..count, " ", &"#{prefix}#{&1}")

  defp tmp_dir do
    directory =
      Path.join(System.tmp_dir!(), "weka-export-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end
end
