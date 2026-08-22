defmodule OpenAgentsWeb.LabelIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenAgents.LabelsFixtures

  alias OpenAgents.Labels

  setup %{conn: conn} do
    {:ok, conn: log_in_repository_user(conn, "label-index", repository())}
  end

  test "mounts with the create form and an empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/labels")

    assert html =~ "Labels"
    assert has_element?(view, "#new-label-form")
    assert has_element?(view, ~s{[role="status"]}, "No labels yet")
    refute has_element?(view, "#labels")
  end

  test "lists seeded labels with their descriptions", %{conn: conn} do
    label_fixture(repository(), %{
      name: "bug",
      color: "d73a4a",
      description: "Something is broken"
    })

    label_fixture(repository(), %{name: "docs", color: "0075ca", description: nil})

    {:ok, view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/labels")

    refute html =~ "No labels yet"
    assert has_element?(view, "#labels")
    assert has_element?(view, "#labels td", "bug")
    assert has_element?(view, "#labels td", "Something is broken")
    assert has_element?(view, "#labels td", "docs")
    # A label with no description renders the em-dash placeholder, not "".
    assert has_element?(view, "#labels td", "—")
  end

  test "submitting the form creates a label and re-renders the table", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/labels")

    html =
      view
      |> form("#new-label-form", label: %{name: "enhancement", color: "a2eeef"})
      |> render_submit()

    assert html =~ "Label created"
    assert has_element?(view, "#labels td", "enhancement")
    assert [%Labels.Label{name: "enhancement"}] = Labels.list_labels(repository())
  end

  test "a label missing its required color re-renders the form with an error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/labels")

    html =
      view
      |> form("#new-label-form", label: %{name: "no-color", color: ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert has_element?(view, "#new-label-form")
    assert Labels.list_labels(repository()) == []
  end

  test "deleting a label removes it and returns the empty state", %{conn: conn} do
    label = label_fixture(repository(), %{name: "wontfix", color: "ffffff"})

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/labels")
    assert has_element?(view, "#labels td", "wontfix")

    html =
      view
      |> element(~s{#labels button[phx-value-id="#{label.id}"]})
      |> render_click()

    assert html =~ "Label deleted"
    assert has_element?(view, ~s{[role="status"]}, "No labels yet")
    assert Labels.list_labels(repository()) == []
  end

  defp repository do
    OpenAgents.Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
