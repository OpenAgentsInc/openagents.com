defmodule OpenAgents.ProjectFieldsTest do
  use OpenAgents.DataCase

  alias OpenAgents.ProjectFields

  setup do
    Process.put({__MODULE__, :repository}, repository_fixture())
    on_exit(fn -> Process.delete({__MODULE__, :repository}) end)
    :ok
  end

  describe "project_fields" do
    alias OpenAgents.ProjectFields.ProjectField

    import OpenAgents.ProjectFieldsFixtures
    import OpenAgents.ProjectsFixtures

    @invalid_attrs %{name: nil, data_type: nil, options: nil, project_id: nil}

    test "list_project_fields/0 returns all project_fields" do
      project_field = project_field_fixture(repository())
      assert ProjectFields.list_project_fields() == [project_field]
    end

    test "list_project_fields/0 returns an empty list when none exist" do
      assert ProjectFields.list_project_fields() == []
    end

    test "list_project_fields/0 spans projects" do
      a = project_field_fixture(repository(), name: "Status")
      b = project_field_fixture(repository(), name: "Priority")

      ids = ProjectFields.list_project_fields() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([a.id, b.id])
    end

    test "get_project_field!/1 returns the project_field with given id" do
      project_field = project_field_fixture(repository())
      assert ProjectFields.get_project_field!(project_field.id) == project_field
    end

    test "get_project_field!/1 raises for an unknown id" do
      project_field = project_field_fixture(repository())

      assert_raise Ecto.NoResultsError, fn ->
        ProjectFields.get_project_field!(project_field.id + 1)
      end
    end

    test "create_project_field/1 with valid data creates a project_field" do
      project = project_fixture(repository())

      valid_attrs = %{
        name: "Status",
        data_type: "single_select",
        options: %{"values" => ["Todo", "Done"]},
        project_id: project.id
      }

      assert {:ok, %ProjectField{} = project_field} =
               ProjectFields.create_project_field(valid_attrs)

      assert project_field.name == "Status"
      assert project_field.data_type == "single_select"
      assert project_field.options == %{"values" => ["Todo", "Done"]}
      assert project_field.project_id == project.id
    end

    test "create_project_field/1 leaves options nil when omitted" do
      project = project_fixture(repository())

      assert {:ok, %ProjectField{} = project_field} =
               ProjectFields.create_project_field(%{
                 name: "Notes",
                 data_type: "text",
                 project_id: project.id
               })

      assert is_nil(project_field.options)
    end

    test "create_project_field/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               ProjectFields.create_project_field(@invalid_attrs)

      assert %{
               name: ["can't be blank"],
               data_type: ["can't be blank"],
               project_id: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "create_project_field/1 requires a project_id" do
      assert {:error, changeset} =
               ProjectFields.create_project_field(%{name: "Status", data_type: "text"})

      assert %{project_id: ["can't be blank"]} = errors_on(changeset)
      refute Map.has_key?(errors_on(changeset), :name)
    end

    test "create_project_field/1 does not declare a foreign key constraint" do
      # `project_fields.project_id` references `projects` in the database but the
      # changeset never calls `foreign_key_constraint/2`, so a dangling id blows
      # up rather than returning an error changeset. Characterised, not endorsed.
      assert_raise Ecto.ConstraintError, fn ->
        ProjectFields.create_project_field(%{
          name: "Status",
          data_type: "text",
          project_id: 2_147_483_000
        })
      end
    end

    test "update_project_field/2 with valid data updates the project_field" do
      project_field = project_field_fixture(repository())

      update_attrs = %{
        name: "some updated name",
        data_type: "some updated data_type",
        options: %{"values" => ["a"]}
      }

      assert {:ok, %ProjectField{} = project_field} =
               ProjectFields.update_project_field(project_field, update_attrs)

      assert project_field.name == "some updated name"
      assert project_field.data_type == "some updated data_type"
      assert project_field.options == %{"values" => ["a"]}
    end

    test "update_project_field/2 can move a field to another project" do
      project_field = project_field_fixture(repository())
      other = project_fixture(repository(), number: 99)

      assert {:ok, %ProjectField{} = moved} =
               ProjectFields.update_project_field(project_field, %{project_id: other.id})

      assert moved.project_id == other.id
    end

    test "update_project_field/2 with invalid data returns error changeset" do
      project_field = project_field_fixture(repository())

      assert {:error, %Ecto.Changeset{}} =
               ProjectFields.update_project_field(project_field, @invalid_attrs)

      assert project_field == ProjectFields.get_project_field!(project_field.id)
    end

    test "delete_project_field/1 deletes the project_field" do
      project_field = project_field_fixture(repository())
      assert {:ok, %ProjectField{}} = ProjectFields.delete_project_field(project_field)

      assert_raise Ecto.NoResultsError, fn ->
        ProjectFields.get_project_field!(project_field.id)
      end
    end

    test "change_project_field/1 returns a project_field changeset" do
      project_field = project_field_fixture(repository())
      assert %Ecto.Changeset{} = ProjectFields.change_project_field(project_field)
    end

    test "change_project_field/2 applies the given attrs" do
      project_field = project_field_fixture(repository())

      changeset = ProjectFields.change_project_field(project_field, %{name: "Renamed"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "Renamed"
    end

    test "change_project_field/2 surfaces validation errors without touching the database" do
      project_field = project_field_fixture(repository())

      changeset = ProjectFields.change_project_field(project_field, %{name: nil})

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert project_field == ProjectFields.get_project_field!(project_field.id)
    end
  end

  defp repository, do: Process.get({__MODULE__, :repository})
end
