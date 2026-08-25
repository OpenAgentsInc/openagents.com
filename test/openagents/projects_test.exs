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
      valid_attrs = %{owner: "some owner", state: "open", title: "some title", number: 42}

      assert {:ok, %Project{} = project} = Projects.create_project(repository(), valid_attrs)
      assert project.owner == "some owner"
      assert project.state == "open"
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
        state: "closed",
        title: "some updated title",
        number: 43
      }

      assert {:ok, %Project{} = project} = Projects.update_project(project, update_attrs)
      assert project.owner == "some updated owner"
      assert project.state == "closed"
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
      # ArgumentError, which the /api/v1 controller does not rescue.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Projects.create_project_item(%{"values" => %{}}, project)

      assert %{issue_id: ["can't be blank"]} = errors_on(changeset)
      assert Projects.list_project_items(project) == []
    end

    test "create_project_item/2 records a source issue from another repository", %{
      project: project
    } do
      source = repository_fixture(%{visibility: "public"})
      source_issue = issue_fixture(source, title: "Cross-repository work")

      assert {:ok, %ProjectItem{} = item} =
               Projects.create_project_item(
                 %{"issue_number" => source_issue.number, "issue_repository_id" => source.id},
                 project
               )

      assert item.issue_id == source_issue.id
      assert item.issue_repository_id == source.id
      assert item.repository_id == project.repository_id
      assert item.issue.repository.id == source.id
    end

    test "create_project_item/2 reads the number in the named source repository", %{
      project: project,
      issue: issue
    } do
      source = repository_fixture(%{visibility: "public"})
      source_issue = issue_fixture(source, title: "Same number, other repository")

      assert source_issue.number == issue.number

      assert {:ok, %ProjectItem{} = item} =
               Projects.create_project_item(
                 %{"issue_number" => source_issue.number, "issue_repository_id" => source.id},
                 project
               )

      assert item.issue_id == source_issue.id
      refute item.issue_id == issue.id
    end

    test "create_project_item/2 returns the membership a repeated add already made", %{
      project: project,
      issue: issue
    } do
      {:ok, item} = Projects.create_project_item(%{"issue_number" => issue.number}, project)

      assert {:ok, repeated} =
               Projects.create_project_item(%{"issue_number" => issue.number}, project)

      assert repeated.id == item.id
      assert length(Projects.list_project_items(project)) == 1
    end

    test "list_visible_project_items/2 omits an unreadable source issue", %{
      project: project,
      issue: issue
    } do
      {:ok, local} = Projects.create_project_item(%{"issue_number" => issue.number}, project)
      private = repository_fixture(%{visibility: "private"})
      private_issue = issue_fixture(private, title: "Private work")

      {:ok, hidden} =
        Projects.create_project_item(
          %{"issue_number" => private_issue.number, "issue_repository_id" => private.id},
          project
        )

      viewer = repository_user_fixture("project-source-viewer")

      assert Enum.map(Projects.list_visible_project_items(project, viewer), & &1.id) == [local.id]
      assert Enum.map(Projects.list_visible_project_items(project, nil), & &1.id) == [local.id]

      {:ok, _membership} = OpenAgents.Repositories.add_member(private, viewer, "viewer")

      assert Projects.list_visible_project_items(project, viewer)
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort([local.id, hidden.id])
    end

    test "get_visible_project_item!/3 hides an unreadable source issue", %{project: project} do
      private = repository_fixture(%{visibility: "private"})
      private_issue = issue_fixture(private, title: "Private work")

      {:ok, hidden} =
        Projects.create_project_item(
          %{"issue_number" => private_issue.number, "issue_repository_id" => private.id},
          project
        )

      viewer = repository_user_fixture("project-item-viewer")

      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_visible_project_item!(project, hidden.id, viewer)
      end

      {:ok, _membership} = OpenAgents.Repositories.add_member(private, viewer, "viewer")

      assert Projects.get_visible_project_item!(project, hidden.id, viewer).id == hidden.id
    end

    test "an item write announces itself on the repository's project topic", %{
      project: project,
      issue: issue
    } do
      :ok = OpenAgents.Repositories.subscribe_projects(repository().id)

      {:ok, item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "values" => %{"Status" => "To Do"}},
          project
        )

      assert_receive {:projects_changed, repository_id}, 500
      assert repository_id == repository().id

      {:ok, _updated} = Projects.update_project_item(item, %{"values" => %{"Status" => "Done"}})

      assert_receive {:projects_changed, repository_id}, 500
      assert repository_id == repository().id
    end

    test "a rejected item write announces nothing", %{project: project, issue: issue} do
      :ok = OpenAgents.Repositories.subscribe_projects(repository().id)

      assert {:error, %Ecto.Changeset{}} =
               Projects.create_project_item(
                 %{"issue_number" => issue.number, "values" => "not-a-map"},
                 project
               )

      refute_receive {:projects_changed, _repository_id}, 100
    end

    test "a repeated add announces nothing", %{project: project, issue: issue} do
      {:ok, _item} = Projects.create_project_item(%{"issue_number" => issue.number}, project)

      :ok = OpenAgents.Repositories.subscribe_projects(repository().id)

      assert {:ok, _repeated} =
               Projects.create_project_item(%{"issue_number" => issue.number}, project)

      refute_receive {:projects_changed, _repository_id}, 100
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
          data_type: "text",
          project_id: project.id
        })

      {:ok, _theirs} =
        Projects.create_project_field(%{
          name: "Status",
          data_type: "text",
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

  describe "project lifecycle" do
    import OpenAgents.ProjectsFixtures

    alias OpenAgents.Projects.Project

    test "create_project/2 refuses a state outside the lifecycle" do
      assert {:error, changeset} =
               Projects.create_project(repository(), %{
                 title: "Roadmap",
                 owner: "OpenAgents",
                 state: "sideways"
               })

      assert %{state: ["is invalid"]} = errors_on(changeset)
    end

    test "the database refuses a state the changeset never produces" do
      project = project_fixture(repository())

      assert_raise Postgrex.Error, ~r/projects_state_check/, fn ->
        OpenAgents.Repo.update_all(
          from(p in Project, where: p.id == ^project.id),
          set: [state: "sideways"]
        )
      end
    end

    test "archive_project/2 and restore_project/2 move a project in and out of the archive" do
      project = project_fixture(repository(), %{title: "Roadmap"})

      assert {:ok, archived} = Projects.archive_project(project, nil)
      assert archived.archived_at
      assert Project.archived?(archived)
      # Archiving is orthogonal to open and closed: a board is retired without
      # claiming the work it tracked is finished.
      assert archived.state == project.state

      assert {:ok, restored} = Projects.restore_project(archived, nil)
      refute restored.archived_at
      refute Project.archived?(restored)
    end

    test "archiving and restoring append actor-attributed activity" do
      user = repository_user_fixture("archivist")
      project = project_fixture(repository(), %{title: "Roadmap"})

      {:ok, archived} = Projects.archive_project(project, user)
      {:ok, _restored} = Projects.restore_project(archived, user)

      {notes, _total} = Projects.list_project_notes_page(project, kind: "activity")
      bodies = Enum.map(notes, &OpenAgents.Projects.ProjectNote.text/1)

      assert Enum.any?(bodies, &(&1 =~ "Archived the project."))
      assert Enum.any?(bodies, &(&1 =~ "Restored the project from the archive."))
      assert Enum.all?(notes, &(&1.author_user_id == user.id))
    end

    test "list_projects/2 excludes archived projects unless asked" do
      kept = project_fixture(repository(), %{title: "Kept"})
      retired = project_fixture(repository(), %{title: "Retired"})
      {:ok, _} = Projects.archive_project(retired, nil)

      assert Enum.map(Projects.list_projects(repository()), & &1.id) == [kept.id]

      assert repository()
             |> Projects.list_projects(archived: true)
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort([kept.id, retired.id])
    end
  end

  describe "project field lifecycle" do
    import OpenAgents.ProjectItemsFixtures

    setup do
      {:ok, project} =
        Projects.create_project(repository(), %{title: "Roadmap", owner: "OpenAgents"})

      %{project: project}
    end

    test "create_project_field/1 refuses a duplicate name on the same project", %{
      project: project
    } do
      attrs = %{"project_id" => project.id, "name" => "Status", "data_type" => "text"}

      assert {:ok, _field} = Projects.create_project_field(attrs)

      assert {:error, changeset} =
               Projects.create_project_field(%{attrs | "name" => "STATUS"})

      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "create_project_field/1 refuses an unsupported data type", %{project: project} do
      assert {:error, changeset} =
               Projects.create_project_field(%{
                 "project_id" => project.id,
                 "name" => "Status",
                 "data_type" => "rocket"
               })

      assert %{data_type: [_ | _]} = errors_on(changeset)
    end

    test "update_project_field/3 rewrites the stored key on every item", %{project: project} do
      {:ok, field} =
        Projects.create_project_field(%{
          "project_id" => project.id,
          "name" => "Status",
          "data_type" => "single_select",
          "options" => %{"values" => ["Todo", "Done"]}
        })

      one =
        project_item_fixture(repository(), %{
          project_id: project.id,
          values: %{"Status" => "Todo"}
        })

      two =
        project_item_fixture(repository(), %{
          project_id: project.id,
          values: %{"Status" => "Done", "Squad" => "Platform"}
        })

      assert {:ok, renamed} = Projects.update_project_field(project, field, %{"name" => "Stage"})
      assert renamed.name == "Stage"

      assert Projects.get_project_item!(project, one.id).values == %{"Stage" => "Todo"}

      assert Projects.get_project_item!(project, two.id).values == %{
               "Stage" => "Done",
               "Squad" => "Platform"
             }
    end

    test "delete_project_field/2 preserves a field an item still carries", %{project: project} do
      {:ok, field} =
        Projects.create_project_field(%{
          "project_id" => project.id,
          "name" => "Status",
          "data_type" => "text"
        })

      project_item_fixture(repository(), %{project_id: project.id, values: %{"Status" => "Todo"}})

      assert {:error, changeset} = Projects.delete_project_field(project, field)
      assert %{name: [_ | _]} = errors_on(changeset)
      assert Projects.get_project_field!(project, field.id)
    end
  end

  describe "project item operations" do
    import OpenAgents.IssuesFixtures
    import OpenAgents.ProjectsFixtures

    alias OpenAgents.ProjectItems.ProjectItem

    setup do
      project = project_fixture(repository(), number: 1)

      {:ok, field} =
        Projects.create_project_field(%{
          "project_id" => project.id,
          "name" => "Status",
          "data_type" => "single_select",
          "options" => %{
            "values" => [
              %{"id" => "todo", "name" => "To Do"},
              %{"id" => "doing", "name" => "In Progress"},
              %{"id" => "done", "name" => "Done"}
            ]
          }
        })

      %{project: project, field: field}
    end

    defp add(project, title, values \\ %{}) do
      issue = issue_fixture(repository(), title: title)

      {:ok, item} =
        Projects.create_project_item(
          %{"issue_number" => issue.number, "values" => values},
          project
        )

      item
    end

    defp order(project) do
      project |> Projects.list_project_items() |> Enum.map(& &1.issue.title)
    end

    test "an added item takes the last position on the board", %{project: project} do
      first = add(project, "First")
      second = add(project, "Second")

      assert first.position < second.position
      assert order(project) == ["First", "Second"]
    end

    test "adding an issue already on the board returns the item it already has", %{
      project: project
    } do
      issue = issue_fixture(repository(), title: "Once")

      {:ok, item} = Projects.create_project_item(%{"issue_number" => issue.number}, project)

      assert {:ok, %ProjectItem{id: id}} =
               Projects.create_project_item(%{"issue_number" => issue.number}, project)

      assert id == item.id
      assert length(Projects.list_project_items(project)) == 1
    end

    test "the same issue sits on two boards at once", %{project: project} do
      other = project_fixture(repository(), number: 2)
      issue = issue_fixture(repository(), title: "Shared")

      assert {:ok, mine} =
               Projects.create_project_item(%{"issue_number" => issue.number}, project)

      assert {:ok, theirs} =
               Projects.create_project_item(%{"issue_number" => issue.number}, other)

      refute mine.id == theirs.id
    end

    test "delete_project_item/2 removes the item and keeps the issue", %{project: project} do
      item = add(project, "Removable")
      issue_id = item.issue_id

      assert {:ok, %ProjectItem{}} = Projects.delete_project_item(item)
      assert Projects.list_project_items(project) == []
      assert OpenAgents.Issues.get_issue!(repository(), issue_id)
    end

    test "delete_project_item/2 records a removal readable after the item is gone", %{
      project: project
    } do
      item = add(project, "Removable")

      {:ok, _removed} = Projects.delete_project_item(item)

      {events, _total, _page, _per_page} = Projects.list_project_item_events(item)
      assert [%{kind: "remove"}, %{kind: "create"}] = events
    end

    test "move_project_item/3 changes the column and appends to its end", %{project: project} do
      first = add(project, "First", %{"Status" => "done"})
      _second = add(project, "Second", %{"Status" => "todo"})
      third = add(project, "Third", %{"Status" => "todo"})

      assert {:ok, moved} =
               Projects.move_project_item(third, %{"values" => %{"Status" => "done"}})

      assert moved.values["Status"] == "done"
      assert moved.position > first.position
    end

    test "move_project_item/3 places an item at a one-based index in its column", %{
      project: project
    } do
      _first = add(project, "First", %{"Status" => "todo"})
      _second = add(project, "Second", %{"Status" => "todo"})
      third = add(project, "Third", %{"Status" => "todo"})

      assert {:ok, _moved} = Projects.move_project_item(third, %{"position" => 1})
      assert order(project) == ["Third", "First", "Second"]
    end

    test "move_project_item/3 clamps a position past the end of the column", %{project: project} do
      first = add(project, "First", %{"Status" => "todo"})
      _second = add(project, "Second", %{"Status" => "todo"})

      assert {:ok, _moved} = Projects.move_project_item(first, %{"position" => 99})
      assert order(project) == ["Second", "First"]
    end

    test "move_project_item/3 refuses an option the field does not offer", %{project: project} do
      item = add(project, "First", %{"Status" => "todo"})

      assert {:error, changeset} =
               Projects.move_project_item(item, %{"values" => %{"Status" => "shipped"}})

      assert %{values: [_ | _]} = errors_on(changeset)
      assert Projects.get_project_item!(project, item.id).values == %{"Status" => "todo"}
    end

    test "move_project_item/3 refuses a position that is not a positive integer", %{
      project: project
    } do
      item = add(project, "First", %{"Status" => "todo"})

      assert {:error, changeset} = Projects.move_project_item(item, %{"position" => 0})
      assert %{position: [_ | _]} = errors_on(changeset)
    end

    test "a move that changes nothing appends no second event", %{project: project} do
      item = add(project, "First", %{"Status" => "todo"})

      assert {:ok, _first} = Projects.move_project_item(item, %{"position" => 1})
      {before, _total, _page, _per} = Projects.list_project_item_events(item)

      assert {:ok, _again} = Projects.move_project_item(item, %{"position" => 1})
      {now, _total, _page, _per} = Projects.list_project_item_events(item)

      assert length(now) == length(before)
    end

    test "two moves onto the same index settle without losing an item", %{project: project} do
      _first = add(project, "First", %{"Status" => "todo"})
      second = add(project, "Second", %{"Status" => "todo"})
      third = add(project, "Third", %{"Status" => "todo"})

      assert {:ok, _} = Projects.move_project_item(second, %{"position" => 1})
      assert {:ok, _} = Projects.move_project_item(third, %{"position" => 1})

      titles = order(project)
      assert length(titles) == 3
      assert Enum.sort(titles) == ["First", "Second", "Third"]
      assert hd(titles) == "Third"
      assert Enum.map(Projects.list_project_items(project), & &1.position) == [1, 2, 3]
    end

    test "board_grouping/1 reads the stored field and its option order", %{project: project} do
      grouping = Projects.board_grouping(project)

      assert grouping.field_name == "Status"
      assert Enum.map(grouping.columns, & &1.id) == ["todo", "doing", "done"]
      assert Enum.map(grouping.columns, & &1.name) == ["To Do", "In Progress", "Done"]
    end

    test "board_grouping/1 falls back to the default columns with no stored field" do
      bare = project_fixture(repository(), number: 3)
      grouping = Projects.board_grouping(bare)

      assert grouping.source == :default
      assert Enum.map(grouping.columns, & &1.name) == ["To Do", "In Progress", "Done"]
    end

    test "board_grouping/1 follows a relabelled option by identifier", %{
      project: project,
      field: field
    } do
      item = add(project, "First", %{"Status" => "doing"})

      {:ok, _field} =
        Projects.update_project_field(project, field, %{
          "options" => %{
            "values" => [
              %{"id" => "todo", "name" => "To Do"},
              %{"id" => "doing", "name" => "Under way"},
              %{"id" => "done", "name" => "Done"}
            ]
          }
        })

      grouping = Projects.board_grouping(project)
      assert Enum.map(grouping.columns, & &1.name) == ["To Do", "Under way", "Done"]
      assert Projects.get_project_item!(project, item.id).values == %{"Status" => "doing"}
    end
  end

  defp repository, do: Process.get({__MODULE__, :repository})
end
