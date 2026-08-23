defmodule Mix.Tasks.Openagents.Promises.BackfillTest do
  use OpenAgents.DataCase

  alias OpenAgents.Issues
  alias OpenAgents.Projects

  import ExUnit.CaptureIO

  test "backfills the curated registry idempotently" do
    repository =
      repository_fixture(%{
        owner: "BackfillOrg",
        name: "backfill-promises",
        visibility: "public"
      })

    {:ok, project} =
      Projects.create_project(repository, %{
        title: "Promises",
        owner: "OpenAgents",
        state: "open"
      })

    args = [
      "--owner",
      repository.owner,
      "--repo",
      repository.name,
      "--project-number",
      to_string(project.number)
    ]

    first_output = capture_io(fn -> Mix.Tasks.Openagents.Promises.Backfill.run(args) end)
    assert first_output =~ "Backfilled 6 promise(s); skipped 0."
    assert length(Projects.list_project_fields(project)) == 1
    assert length(Projects.list_project_items(project)) == 6
    assert length(Issues.list_issues(repository, state: "all")) == 6
    assert Enum.all?(Issues.list_issues(repository, state: "all"), &(&1.state == "open"))

    Mix.Task.reenable("openagents.promises.backfill")

    second_output = capture_io(fn -> Mix.Tasks.Openagents.Promises.Backfill.run(args) end)
    assert second_output =~ "Backfilled 0 promise(s); skipped 6."
    assert length(Projects.list_project_fields(project)) == 1
    assert length(Projects.list_project_items(project)) == 6
    assert length(Issues.list_issues(repository, state: "all")) == 6
  end

  test "skips an unresolved LIVE promise and continues with later promises" do
    repository =
      repository_fixture(%{
        owner: "BackfillSkipOrg",
        name: "backfill-skip",
        visibility: "public"
      })

    {:ok, project} =
      Projects.create_project(repository, %{
        title: "Promises",
        owner: "OpenAgents",
        state: "open"
      })

    path =
      Path.join(
        System.tmp_dir!(),
        "promises-curated-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.write!(
      path,
      Jason.encode!([
        %{
          "id" => "unresolved_live",
          "state" => "LIVE",
          "problem" => "A problem",
          "claim" => "A claim",
          "scope" => "A scope",
          "acceptance_criteria" => ["A criterion"],
          "success_metrics" => ["A metric"],
          "owner" => "OpenAgents",
          "target" => "2026-12-31",
          "evidence" => [
            %{
              "kind" => "accepted_outcome",
              "decision_receipt_ref" => "missing-decision"
            }
          ]
        },
        %{
          "id" => "later_gated",
          "state" => "GATED",
          "problem" => "A problem",
          "claim" => "A claim",
          "scope" => "A scope",
          "acceptance_criteria" => ["A criterion"],
          "success_metrics" => ["A metric"],
          "owner" => "OpenAgents",
          "target" => "2026-12-31",
          "gate" => %{
            "missing" => "A receipt",
            "owner" => "OpenAgents",
            "next_review" => "2026-09-01"
          },
          "evidence" => []
        }
      ])
    )

    previous = Application.get_env(:openagents, :promises_curated_path)
    Application.put_env(:openagents, :promises_curated_path, path)

    on_exit(fn ->
      if previous do
        Application.put_env(:openagents, :promises_curated_path, previous)
      else
        Application.delete_env(:openagents, :promises_curated_path)
      end

      File.rm(path)
    end)

    args = [
      "--owner",
      repository.owner,
      "--repo",
      repository.name,
      "--project-number",
      to_string(project.number)
    ]

    output = capture_io(fn -> Mix.Tasks.Openagents.Promises.Backfill.run(args) end)

    assert output =~ "Skipped unresolved_live: LIVE gate failed:"
    assert output =~ "Backfilled 1 promise(s); skipped 1."
    assert length(Projects.list_project_items(project)) == 1
    assert length(Issues.list_issues(repository, state: "all")) == 2
  end
end
