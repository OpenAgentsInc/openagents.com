defmodule OpenAgents.ProjectsTest do
  use OpenAgents.DataCase

  alias OpenAgents.Projects

  setup do
    Process.put({__MODULE__, :repository}, repository_fixture())
    on_exit(fn -> Process.delete({__MODULE__, :repository}) end)
    :ok
  end

  describe "projects" do
    alias OpenAgents.Projects.Project

    import OpenAgents.ProjectsFixtures

    @invalid_attrs %{owner: nil, state: nil, title: nil, number: nil}

    test "list_projects/0 returns all projects" do
      project = project_fixture(repository())
      assert Projects.list_projects(repository()) == [project]
    end

    test "get_project!/1 returns the project with given id" do
      project = project_fixture(repository())
      assert Projects.get_project!(repository(), project.id) == project
    end

    test "create_project/1 with valid data creates a project" do
      valid_attrs = %{owner: "some owner", state: "some state", title: "some title", number: 42}

      assert {:ok, %Project{} = project} = Projects.create_project(repository(), valid_attrs)
      assert project.owner == "some owner"
      assert project.state == "some state"
      assert project.title == "some title"
      assert project.number == 42
    end

    test "create_project/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(repository(), @invalid_attrs)
    end

    test "update_project/2 with valid data updates the project" do
      project = project_fixture(repository())

      update_attrs = %{
        owner: "some updated owner",
        state: "some updated state",
        title: "some updated title",
        number: 43
      }

      assert {:ok, %Project{} = project} = Projects.update_project(project, update_attrs)
      assert project.owner == "some updated owner"
      assert project.state == "some updated state"
      assert project.title == "some updated title"
      assert project.number == 43
    end

    test "update_project/2 with invalid data returns error changeset" do
      project = project_fixture(repository())
      assert {:error, %Ecto.Changeset{}} = Projects.update_project(project, @invalid_attrs)
      assert project == Projects.get_project!(repository(), project.id)
    end

    test "delete_project/1 deletes the project" do
      project = project_fixture(repository())
      assert {:ok, %Project{}} = Projects.delete_project(project)
      assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(repository(), project.id) end
    end

    test "change_project/1 returns a project changeset" do
      project = project_fixture(repository())
      assert %Ecto.Changeset{} = Projects.change_project(project)
    end

    test "change_project/2 applies the given attrs" do
      project = project_fixture(repository())

      changeset = Projects.change_project(project, %{title: "Renamed"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :title) == "Renamed"
    end

    test "change_project/2 surfaces validation errors" do
      project = project_fixture(repository())

      changeset = Projects.change_project(project, %{title: nil})

      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_project/1 defaults state to open" do
      assert {:ok, %Project{} = project} =
               Projects.create_project(repository(), %{title: "Roadmap", owner: "OpenAgents"})

      assert project.state == "open"
    end

    test "create_project/1 assigns the next number when none is given" do
      assert {:ok, %Project{number: 1}} =
               Projects.create_project(repository(), %{title: "One", owner: "OpenAgents"})

      assert {:ok, %Project{number: 2}} =
               Projects.create_project(repository(), %{title: "Two", owner: "OpenAgents"})

      assert {:ok, %Project{number: 3}} =
               Projects.create_project(repository(), %{title: "Three", owner: "OpenAgents"})
    end

    test "create_project/1 honours an explicit number and continues from it" do
      assert {:ok, %Project{number: 10}} =
               Projects.create_project(repository(), %{
                 title: "Ten",
                 owner: "OpenAgents",
                 number: 10
               })

      assert {:ok, %Project{number: 11}} =
               Projects.create_project(repository(), %{title: "Next", owner: "OpenAgents"})
    end

    test "create_project/0 refuses an empty project" do
      assert {:error, %Ecto.Changeset{} = changeset} = Projects.create_project(repository(), %{})
      assert %{title: ["can't be blank"], owner: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_project/1 accepts string keys" do
      assert {:ok, %Project{} = project} =
               Projects.create_project(repository(), %{
                 "title" => "Strings",
                 "owner" => "OpenAgents"
               })

      assert project.title == "Strings"
      assert project.owner == "OpenAgents"
      assert project.number == 1
    end

    test "get_project_by_number!/1 returns the project with the given number" do
      project = project_fixture(repository(), number: 7)
      assert Projects.get_project_by_number!(repository(), 7) == project
    end

    test "get_project_by_number!/1 raises for an unknown number" do
      project_fixture(repository(), number: 7)
      assert_raise Ecto.NoResultsError, fn -> Projects.get_project_by_number!(repository(), 8) end
    end
  end

  describe "project items" do
    alias OpenAgents.ProjectItems.ProjectItem

    import OpenAgents.IssuesFixtures
    import OpenAgents.ProjectsFixtures

    setup do
      project = project_fixture(repository(), number: 1)
      issue = issue_fixture(repository(), title: "First issue")
      %{project: project, issue: issue}
    end

    test "list_project_items/1 is scoped to one project", %{project: project, issue: issue} do
      other = project_fixture(repository(), number: 2)

      {:ok, mine} =
        Projects.create_project_item(%{"issue_number" => issue.number}, project)

      {:ok, _theirs} =
        Projects.create_project_item(%{"issue_number" => issue.number}, other)

      assert Enum.map(Projects.list_project_items(project), & &1.id) == [mine.id]
    end

    test "list_project_items/1 returns an empty list for a project with no items", %{
      project: project
    } do
      assert Projects.list_project_items(project) == []
    end

    test "get_project_item!/1 returns the item", %{project: project, issue: issue} do
      {:ok, item} = Projects.create_project_item(%{"issue_number" => issue.number}, project)
      assert Projects.get_project_item!(project, item.id) == item
    end

    test "get_project_item!/1 raises for an unknown id", %{project: project, issue: issue} do
      {:ok, item} = Projects.create_project_item(%{"issue_number" => issue.number}, project)
      assert_raise Ecto.NoResultsError, fn -> Projects.get_project_item!(project, item.id + 1) end
    end

    test "create_project_item/2 resolves the issue by number", %{project: project, issue: issue} do
      assert {:ok, %ProjectItem{} = item} =
               Projects.create_project_item(
                 %{"issue_number" => issue.number, "values" => %{"Status" => "Todo"}},
                 project
               )

      assert item.project_id == project.id
      assert item.issue_id == issue.id
      assert item.values == %{"Status" => "Todo"}
    end

    test "create_project_item/2 defaults values to an empty map", %{
      project: project,
      issue: issue
    } do
      assert {:ok, %ProjectItem{} = item} =
               Projects.create_project_item(%{"issue_number" => issue.number}, project)

      assert item.values == %{}
    end

    test "create_project_item/2 keeps values given with atom keys", %{
      project: project,
      issue: issue
    } do
      # Regression: an atom-keyed clause used to read `attrs["values"]`, which is
      # always nil for an atom-keyed map, so the caller's values were dropped.
      assert {:ok, %ProjectItem{} = item} =
               Projects.create_project_item(
                 %{issue_number: issue.number, values: %{"Status" => "Todo"}},
                 project
               )

      assert item.issue_id == issue.id
      assert item.values == %{"Status" => "Todo"}
    end

    test "create_project_item/2 ignores extra params from the router", %{
      project: project,
      issue: issue
    } do
      assert {:ok, %ProjectItem{} = item} =
               Projects.create_project_item(
                 %{
                   "username" => "OpenAgents",
                   "project_number" => "1",
                   "issue_number" => issue.number
                 },
                 project
               )

      assert item.issue_id == issue.id
    end

    test "create_project_item/2 raises when the issue number is unknown", %{project: project} do
      assert_raise Ecto.NoResultsError, fn ->
        Projects.create_project_item(%{"issue_number" => 9999}, project)
      end
    end

    test "create_project_item/2 returns an error changeset when no issue number is given", %{
      project: project
    } do
      # Regression: a nil issue number used to reach `Repo.get_by!` and raise
      # ArgumentError, which the /api/v3 controller does not rescue.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Projects.create_project_item(%{"values" => %{}}, project)

      assert %{issue_id: ["can't be blank"]} = errors_on(changeset)
      assert Projects.list_project_items(project) == []
    end

    test "update_project_item/2 merges into existing values", %{
      project: project,
      issue: issue
    } do
      {:ok, item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "values" => %{"Status" => "Todo", "Size" => "L"}},
          project
        )

      assert {:ok, %ProjectItem{} = updated} =
               Projects.update_project_item(item, %{"values" => %{"Status" => "Done"}})

      assert updated.values == %{"Status" => "Done", "Size" => "L"}
    end

    test "update_project_item/2 accepts atom keys", %{project: project, issue: issue} do
      {:ok, item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "values" => %{"Status" => "Todo"}},
          project
        )

      assert {:ok, %ProjectItem{} = updated} =
               Projects.update_project_item(item, %{values: %{"Size" => "S"}})

      assert updated.values == %{"Status" => "Todo", "Size" => "S"}
    end

    test "update_project_item/2 leaves values alone when none are given", %{
      project: project,
      issue: issue
    } do
      {:ok, item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "values" => %{"Status" => "Todo"}},
          project
        )

      assert {:ok, %ProjectItem{} = updated} =
               Projects.update_project_item(item, %{"username" => "OpenAgents"})

      assert updated.values == %{"Status" => "Todo"}
    end

    test "update_project_item/2 tolerates an item whose values are nil", %{
      project: project,
      issue: issue
    } do
      {:ok, item} =
        OpenAgents.ProjectItems.create_project_item(repository(), %{
          project_id: project.id,
          issue_id: issue.id
        })

      assert is_nil(item.values)

      assert {:ok, %ProjectItem{} = updated} =
               Projects.update_project_item(item, %{"values" => %{"Status" => "Todo"}})

      assert updated.values == %{"Status" => "Todo"}
    end
  end

  describe "project fields" do
    alias OpenAgents.ProjectFields.ProjectField

    import OpenAgents.ProjectsFixtures

    test "list_project_fields/1 is scoped to one project" do
      project = project_fixture(repository(), number: 1)
      other = project_fixture(repository(), number: 2)

      {:ok, mine} =
        Projects.create_project_field(%{
          name: "Status",
          data_type: "single_select",
          project_id: project.id
        })

      {:ok, _theirs} =
        Projects.create_project_field(%{
          name: "Status",
          data_type: "single_select",
          project_id: other.id
        })

      assert Enum.map(Projects.list_project_fields(project), & &1.id) == [mine.id]
    end

    test "list_project_fields/1 returns an empty list for a project with no fields" do
      project = project_fixture(repository())
      assert Projects.list_project_fields(project) == []
    end

    test "create_project_field/1 with valid data creates a field" do
      project = project_fixture(repository())

      assert {:ok, %ProjectField{} = field} =
               Projects.create_project_field(%{
                 name: "Status",
                 data_type: "single_select",
                 options: %{"values" => ["Todo", "Done"]},
                 project_id: project.id
               })

      assert field.name == "Status"
      assert field.data_type == "single_select"
      assert field.options == %{"values" => ["Todo", "Done"]}
      assert field.project_id == project.id
    end

    test "create_project_field/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} = Projects.create_project_field(%{})

      assert %{
               name: ["can't be blank"],
               data_type: ["can't be blank"],
               project_id: ["can't be blank"]
             } = errors_on(changeset)
    end
  end

  defp repository, do: Process.get({__MODULE__, :repository})
end
