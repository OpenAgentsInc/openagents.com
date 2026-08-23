defmodule OpenAgents.PromiseRegistryTest do
  use OpenAgents.DataCase

  alias OpenAgents.Issues
  alias OpenAgents.Projects
  alias OpenAgents.Projects.ProjectItemEvent
  alias OpenAgents.Projects.PromiseRegistry

  import OpenAgents.CompensationFixtures
  import OpenAgents.IssuesFixtures
  import OpenAgents.ProjectsFixtures

  setup do
    repository = repository_fixture()
    project = project_fixture(repository)

    {:ok, _field} =
      Projects.create_project_field(%{
        project_id: project.id,
        name: "Promise state",
        data_type: "promise_state",
        options: %{"values" => ["LIVE", "GATED", "WITHDRAWN"]}
      })

    %{project: project, repository: repository}
  end

  test "LIVE requires an accepted outcome evidence entry", %{
    project: project,
    repository: repository
  } do
    issue = issue_fixture(repository)

    assert {:error, changeset} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => promise_values("LIVE", %{})},
               project
             )

    assert %{values: ["LIVE requires at least one accepted-outcome evidence entry"]} =
             errors_on(changeset)

    {:ok, _closed_issue} = Issues.update_issue(issue, %{"state" => "closed"})

    decision = outcome_decision_fixture()

    values =
      promise_values("LIVE", %{
        "evidence" => [
          %{
            "kind" => "accepted_outcome",
            "decision_receipt_ref" => decision.decision_receipt_ref
          }
        ]
      })

    assert {:ok, item} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => values},
               project
             )

    assert %DateTime{} = get_in(item.values, ["promise", "verified_at"])
  end

  test "links do not satisfy LIVE and clients cannot set verification time", %{
    project: project,
    repository: repository
  } do
    issue = issue_fixture(repository)

    values =
      promise_values("LIVE", %{
        "verified_at" => "2026-01-01T00:00:00Z",
        "evidence" => [%{"kind" => "link", "url" => "https://example.com/evidence"}]
      })

    assert {:error, changeset} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => values},
               project
             )

    assert %{values: ["LIVE requires at least one accepted-outcome evidence entry"]} =
             errors_on(changeset)

    gated_values =
      promise_values("GATED", %{
        "verified_at" => "2026-01-01T00:00:00Z",
        "gate" => gate()
      })

    assert {:ok, item} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => gated_values},
               project
             )

    refute Map.has_key?(item.values["promise"], "verified_at")
  end

  test "closed issue, changelog, and forge receipt evidence do not satisfy LIVE", %{
    project: project,
    repository: repository
  } do
    issue = issue_fixture(repository)
    {:ok, _closed_issue} = Issues.update_issue(issue, %{"state" => "closed"})

    for evidence <- [
          %{
            "kind" => "issue",
            "owner" => repository.owner,
            "repo" => repository.name,
            "number" => issue.number
          },
          %{"kind" => "changelog", "slug" => "missing-entry"},
          %{"kind" => "receipt", "id" => Ecto.UUID.generate()}
        ] do
      values = promise_values("LIVE", %{"evidence" => [evidence]})

      assert {:error, changeset} =
               Projects.create_project_item(
                 %{"issue_number" => issue.number, "values" => values},
                 project
               )

      assert %{values: ["LIVE requires at least one accepted-outcome evidence entry"]} =
               errors_on(changeset)
    end
  end

  test "accepted outcome evidence resolves only an accepted decision", %{
    project: project,
    repository: repository
  } do
    issue = issue_fixture(repository)
    rejected = outcome_decision_fixture("rejected", "utility_failed")

    rejected_values =
      promise_values("LIVE", %{
        "evidence" => [
          %{
            "kind" => "accepted_outcome",
            "decision_receipt_ref" => rejected.decision_receipt_ref
          }
        ]
      })

    assert {:error, changeset} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => rejected_values},
               project
             )

    assert %{values: ["LIVE requires at least one accepted-outcome evidence entry"]} =
             errors_on(changeset)
  end

  test "readable open issue evidence remains visible but cannot satisfy LIVE", %{
    project: project,
    repository: repository
  } do
    issue = issue_fixture(repository)

    evidence = %{
      "kind" => "issue",
      "owner" => repository.owner,
      "repo" => repository.name,
      "number" => issue.number
    }

    assert PromiseRegistry.readable_evidence?(evidence, nil)
    refute PromiseRegistry.resolvable_evidence?(evidence, nil)

    values = promise_values("GATED", %{"evidence" => [evidence], "gate" => gate()})

    assert {:ok, item} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => values},
               project
             )

    assert get_in(item.values, ["promise", "evidence"]) == [evidence]
  end

  test "GATED requires a complete gate", %{project: project, repository: repository} do
    issue = issue_fixture(repository)
    values = promise_values("GATED", %{})

    assert {:error, changeset} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => values},
               project
             )

    assert %{values: ["GATED requires gate.missing, gate.owner, and gate.next_review"]} =
             errors_on(changeset)
  end

  test "WITHDRAWN requires a replacement path", %{project: project, repository: repository} do
    issue = issue_fixture(repository)
    values = promise_values("WITHDRAWN", %{})

    assert {:error, changeset} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => values},
               project
             )

    assert %{
             values: [
               "WITHDRAWN requires withdrawal.reason, withdrawal.replacement, and withdrawal.date"
             ]
           } =
             errors_on(changeset)
  end

  test "promise IDs are unique within a project", %{project: project, repository: repository} do
    first_issue = issue_fixture(repository)
    second_issue = issue_fixture(repository)
    values = promise_values("GATED", %{"gate" => gate()})

    assert {:ok, _item} =
             Projects.create_project_item(
               %{"issue_number" => first_issue.number, "values" => values},
               project
             )

    assert {:error, changeset} =
             Projects.create_project_item(
               %{"issue_number" => second_issue.number, "values" => values},
               project
             )

    assert %{values: ["promise.id must be unique within this project"]} = errors_on(changeset)
  end

  test "promise item events identify the actor and state transition", %{
    project: project,
    repository: repository
  } do
    issue = issue_fixture(repository)
    actor = repository_user_fixture("promise-event-actor")
    values = promise_values("GATED", %{"gate" => gate()})

    assert {:ok, item} =
             Projects.create_project_item(
               %{"issue_number" => issue.number, "values" => values},
               project,
               actor
             )

    {[created], 1, 1, 25} = Projects.list_project_item_events(item)
    assert created.actor_user_id == actor.id
    assert created.actor_login == actor.github_login
    assert created.kind == "create"
    assert created.from_state == nil
    assert created.to_state == "GATED"

    updated_values = Map.put(values, "Promise state", "WITHDRAWN")

    updated_values =
      Map.put(updated_values, "promise", Map.put(values["promise"], "withdrawal", withdrawal()))

    assert {:ok, updated} =
             Projects.update_project_item(item, %{"values" => updated_values}, actor)

    {[state_change, _created], 2, 1, 25} = Projects.list_project_item_events(updated)
    assert state_change.kind == "state_change"
    assert state_change.from_state == "GATED"
    assert state_change.to_state == "WITHDRAWN"
  end

  test "promise item events are append-only", %{project: project, repository: repository} do
    issue = issue_fixture(repository)
    values = promise_values("GATED", %{"gate" => gate()})

    {:ok, item} =
      Projects.create_project_item(%{"issue_number" => issue.number, "values" => values}, project)

    {[event], 1, 1, 25} = Projects.list_project_item_events(item)

    assert_raise Postgrex.Error, ~r/project item events are append-only/, fn ->
      Repo.update_all(
        from(stored in ProjectItemEvent, where: stored.id == ^event.id),
        set: [kind: "tampered"]
      )
    end

    assert_raise Postgrex.Error, ~r/project item events are append-only/, fn ->
      Repo.delete!(event)
    end
  end

  test "deleting a promise project leaves its event history", %{
    project: project,
    repository: repository
  } do
    issue = issue_fixture(repository)
    values = promise_values("GATED", %{"gate" => gate()})

    {:ok, item} =
      Projects.create_project_item(%{"issue_number" => issue.number, "values" => values}, project)

    {[event], 1, 1, 25} = Projects.list_project_item_events(item)

    assert {:ok, _deleted} = Projects.delete_project(project)
    assert Repo.get(ProjectItemEvent, event.id)
  end

  defp promise_values(state, extra) do
    promise =
      %{
        "id" => "promise_registry_v1",
        "problem" => "A problem",
        "claim" => "A claim",
        "scope" => "A scope",
        "acceptance_criteria" => ["A criterion"],
        "success_metrics" => ["A metric"],
        "owner" => "OpenAgents",
        "target" => "2026-12-31",
        "evidence" => []
      }
      |> Map.merge(extra)

    %{"Promise state" => state, "promise" => promise}
  end

  defp gate do
    %{"missing" => "A receipt", "owner" => "OpenAgents", "next_review" => "2026-09-01"}
  end

  defp withdrawal do
    %{"reason" => "Replaced", "replacement" => "A new promise", "date" => "2026-08-23"}
  end
end
