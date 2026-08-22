defmodule OpenAgents.ProjectItemsTest do
  use OpenAgents.DataCase

  alias OpenAgents.ProjectItems

  setup do
    Process.put({__MODULE__, :repository}, repository_fixture())
    on_exit(fn -> Process.delete({__MODULE__, :repository}) end)
    :ok
  end

  describe "project_items" do
    alias OpenAgents.ProjectItems.ProjectItem

    import OpenAgents.IssuesFixtures
    import OpenAgents.ProjectItemsFixtures
    import OpenAgents.ProjectsFixtures

    @invalid_attrs %{values: nil, project_id: nil, issue_id: nil}

    test "list_project_items/0 returns all project_items" do
      project_item = project_item_fixture(repository())
      assert ProjectItems.list_project_items(repository()) == [project_item]
    end

    test "list_project_items/0 returns an empty list when none exist" do
      assert ProjectItems.list_project_items(repository()) == []
    end

    test "list_project_items/0 is not scoped to a project" do
      a = project_item_fixture(repository())
      b = project_item_fixture(repository())

      refute a.project_id == b.project_id

      ids = ProjectItems.list_project_items(repository()) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([a.id, b.id])
    end

    test "get_project_item!/1 returns the project_item with given id" do
      project_item = project_item_fixture(repository())
      assert ProjectItems.get_project_item!(repository(), project_item.id) == project_item
    end

    test "get_project_item!/1 raises for an unknown id" do
      project_item = project_item_fixture(repository())

      assert_raise Ecto.NoResultsError, fn ->
        ProjectItems.get_project_item!(repository(), project_item.id + 1)
      end
    end

    test "create_project_item/1 with valid data creates a project_item" do
      project = project_fixture(repository())
      issue = issue_fixture(repository())

      valid_attrs = %{
        values: %{"Status" => "In Progress"},
        project_id: project.id,
        issue_id: issue.id
      }

      assert {:ok, %ProjectItem{} = project_item} =
               ProjectItems.create_project_item(repository(), valid_attrs)

      assert project_item.values == %{"Status" => "In Progress"}
      assert project_item.project_id == project.id
      assert project_item.issue_id == issue.id
    end

    test "create_project_item/1 leaves values nil when omitted" do
      project = project_fixture(repository())
      issue = issue_fixture(repository())

      assert {:ok, %ProjectItem{} = project_item} =
               ProjectItems.create_project_item(repository(), %{
                 project_id: project.id,
                 issue_id: issue.id
               })

      assert is_nil(project_item.values)
    end

    test "create_project_item/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               ProjectItems.create_project_item(repository(), @invalid_attrs)

      assert %{project_id: ["can't be blank"], issue_id: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "create_project_item/1 does not require values" do
      assert {:error, changeset} = ProjectItems.create_project_item(repository(), %{values: %{}})

      refute Map.has_key?(errors_on(changeset), :values)

      assert %{project_id: ["can't be blank"], issue_id: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "create_project_item/1 requires an issue_id even with a project" do
      project = project_fixture(repository())

      assert {:error, changeset} =
               ProjectItems.create_project_item(repository(), %{project_id: project.id})

      assert %{issue_id: ["can't be blank"]} = errors_on(changeset)
      refute Map.has_key?(errors_on(changeset), :project_id)
    end

    test "create_project_item/1 reports a dangling project as a changeset error" do
      issue = issue_fixture(repository())

      assert {:error, changeset} =
               ProjectItems.create_project_item(repository(), %{
                 project_id: 2_147_483_000,
                 issue_id: issue.id
               })

      assert %{project_id: ["does not exist"]} = errors_on(changeset)
    end

    test "create_project_item/1 allows the same issue in two projects" do
      issue = issue_fixture(repository())
      one = project_fixture(repository(), number: 1)
      two = project_fixture(repository(), number: 2)

      assert {:ok, %ProjectItem{}} =
               ProjectItems.create_project_item(repository(), %{
                 project_id: one.id,
                 issue_id: issue.id
               })

      assert {:ok, %ProjectItem{}} =
               ProjectItems.create_project_item(repository(), %{
                 project_id: two.id,
                 issue_id: issue.id
               })

      assert length(ProjectItems.list_project_items(repository())) == 2
    end

    test "update_project_item/2 with valid data updates the project_item" do
      project_item = project_item_fixture(repository())
      update_attrs = %{values: %{"Status" => "Done"}}

      assert {:ok, %ProjectItem{} = project_item} =
               ProjectItems.update_project_item(project_item, update_attrs)

      assert project_item.values == %{"Status" => "Done"}
    end

    test "update_project_item/2 replaces values wholesale rather than merging" do
      project_item =
        project_item_fixture(repository(), values: %{"Status" => "Todo", "Size" => "L"})

      assert {:ok, %ProjectItem{} = updated} =
               ProjectItems.update_project_item(project_item, %{values: %{"Status" => "Done"}})

      assert updated.values == %{"Status" => "Done"}
    end

    test "update_project_item/2 with invalid data returns error changeset" do
      project_item = project_item_fixture(repository())

      assert {:error, %Ecto.Changeset{}} =
               ProjectItems.update_project_item(project_item, @invalid_attrs)

      assert project_item == ProjectItems.get_project_item!(repository(), project_item.id)
    end

    test "delete_project_item/1 deletes the project_item" do
      project_item = project_item_fixture(repository())
      assert {:ok, %ProjectItem{}} = ProjectItems.delete_project_item(project_item)

      assert_raise Ecto.NoResultsError, fn ->
        ProjectItems.get_project_item!(repository(), project_item.id)
      end
    end

    test "change_project_item/1 returns a project_item changeset" do
      project_item = project_item_fixture(repository())
      assert %Ecto.Changeset{} = ProjectItems.change_project_item(project_item)
    end

    test "change_project_item/2 applies the given attrs" do
      project_item = project_item_fixture(repository())

      changeset = ProjectItems.change_project_item(project_item, %{values: %{"Status" => "Done"}})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :values) == %{"Status" => "Done"}
    end

    test "change_project_item/2 surfaces validation errors without touching the database" do
      project_item = project_item_fixture(repository())

      changeset = ProjectItems.change_project_item(project_item, %{issue_id: nil})

      refute changeset.valid?
      assert %{issue_id: ["can't be blank"]} = errors_on(changeset)
      assert project_item == ProjectItems.get_project_item!(repository(), project_item.id)
    end
  end

  defp repository, do: Process.get({__MODULE__, :repository})
end
