defmodule OpenAgents.ProjectsTest do
  use OpenAgents.DataCase

  alias OpenAgents.Projects

  describe "projects" do
    alias OpenAgents.Projects.Project

    import OpenAgents.ProjectsFixtures

    @invalid_attrs %{owner: nil, state: nil, title: nil, number: nil}

    test "list_projects/0 returns all projects" do
      project = project_fixture()
      assert Projects.list_projects() == [project]
    end

    test "get_project!/1 returns the project with given id" do
      project = project_fixture()
      assert Projects.get_project!(project.id) == project
    end

    test "create_project/1 with valid data creates a project" do
      valid_attrs = %{owner: "some owner", state: "some state", title: "some title", number: 42}

      assert {:ok, %Project{} = project} = Projects.create_project(valid_attrs)
      assert project.owner == "some owner"
      assert project.state == "some state"
      assert project.title == "some title"
      assert project.number == 42
    end

    test "create_project/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(@invalid_attrs)
    end

    test "update_project/2 with valid data updates the project" do
      project = project_fixture()

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
      project = project_fixture()
      assert {:error, %Ecto.Changeset{}} = Projects.update_project(project, @invalid_attrs)
      assert project == Projects.get_project!(project.id)
    end

    test "delete_project/1 deletes the project" do
      project = project_fixture()
      assert {:ok, %Project{}} = Projects.delete_project(project)
      assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(project.id) end
    end

    test "change_project/1 returns a project changeset" do
      project = project_fixture()
      assert %Ecto.Changeset{} = Projects.change_project(project)
    end
  end
end
