defmodule OpenAgents.ProjectNotesTest do
  use OpenAgents.DataCase

  import OpenAgents.ProjectsFixtures

  alias OpenAgents.Projects

  setup do
    repository = repository_fixture()
    author = repository_user_fixture("note-author-#{System.unique_integer([:positive])}")

    {:ok, project} =
      Projects.create_project(repository, %{title: "Stress testing", owner: author.github_login})

    %{repository: repository, project: project, author: author}
  end

  describe "descriptions" do
    test "a project carries a Markdown description through create and update", %{
      repository: repository,
      author: author
    } do
      {:ok, project} =
        Projects.create_project(repository, %{
          title: "Ox alpha",
          owner: author.github_login,
          description: "## Why\n\nProvider order is the thing under test."
        })

      assert project.description =~ "Provider order"

      assert {:ok, updated} =
               Projects.update_project(project, %{"description" => "Rewritten."}, author)

      assert updated.description == "Rewritten."
    end

    test "an update records one immutable activity note per changed field", %{
      project: project,
      author: author
    } do
      assert {:ok, _updated} =
               Projects.update_project(
                 project,
                 %{"title" => "Stress testing Ox Alpha", "state" => "closed"},
                 author
               )

      {notes, total} = Projects.list_project_notes_page(project, kind: "activity")

      assert total == 2
      assert Enum.all?(notes, &(&1.kind == "activity"))
      assert Enum.any?(notes, &(&1.body =~ "state"))
      assert Enum.any?(notes, &(&1.body =~ "title"))
      assert Enum.all?(notes, &(&1.author == %{"login" => author.github_login}))

      assert [activity | _] = notes
      assert {:error, :immutable} = Projects.update_project_note(activity, %{"body" => "nope"})
      assert {:error, :immutable} = Projects.delete_project_note(activity)
    end

    test "a failed update writes no activity note", %{project: project, author: author} do
      assert {:error, %Ecto.Changeset{}} =
               Projects.update_project(project, %{"title" => nil}, author)

      assert Projects.count_project_notes(project) == 0
    end
  end

  describe "notes" do
    test "a note keeps its Markdown body, author, and timestamps", %{
      project: project,
      author: author
    } do
      assert {:ok, note} =
               Projects.create_project_note(project, %{"body" => "- paused lane 3"}, author)

      assert note.body == "- paused lane 3"
      assert note.kind == "note"
      assert note.author == %{"login" => author.github_login}
      assert note.author_user_id == author.id
      assert note.inserted_at
      assert note.updated_at
    end

    test "a note cannot be created as an activity entry", %{project: project, author: author} do
      assert {:ok, note} =
               Projects.create_project_note(
                 project,
                 %{"body" => "Not a record", "kind" => "activity"},
                 author
               )

      assert note.kind == "note"
    end

    test "a blank body is rejected", %{project: project, author: author} do
      assert {:error, changeset} =
               Projects.create_project_note(project, %{"body" => "   "}, author)

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "notes list newest first, one page at a time", %{project: project, author: author} do
      per_page = Projects.notes_per_page()

      for index <- 1..(per_page + 3) do
        {:ok, _note} = Projects.create_project_note(project, %{"body" => "note #{index}"}, author)
      end

      {first_page, total} = Projects.list_project_notes_page(project, page: 1)
      {second_page, ^total} = Projects.list_project_notes_page(project, page: 2)

      assert total == per_page + 3
      assert length(first_page) == per_page
      assert length(second_page) == 3
      assert hd(first_page).body == "note #{per_page + 3}"
      assert List.last(second_page).body == "note 1"
    end

    test "a note belongs to one project", %{project: project, author: author} do
      other = project_fixture(project.repository_id |> repository!(), %{title: "Other"})
      {:ok, _note} = Projects.create_project_note(project, %{"body" => "mine"}, author)

      assert {[], 0} = Projects.list_project_notes_page(other)
    end

    test "only the author may edit or delete a note", %{project: project, author: author} do
      other = repository_user_fixture("other-#{System.unique_integer([:positive])}")
      {:ok, note} = Projects.create_project_note(project, %{"body" => "mine"}, author)

      assert Projects.authored_by?(note, author)
      refute Projects.authored_by?(note, other)
      refute Projects.authored_by?(note, nil)

      assert {:ok, edited} = Projects.update_project_note(note, %{"body" => "mine, edited"})
      assert edited.body == "mine, edited"
      assert {:ok, _deleted} = Projects.delete_project_note(edited)
      assert Projects.count_project_notes(project) == 0
    end

    test "a note written without an author has no editor", %{project: project} do
      assert {:ok, note} = Projects.create_project_note(project, %{"body" => "by a token"})
      assert note.author == nil

      refute Projects.authored_by?(
               note,
               repository_user_fixture("nobody-#{System.unique_integer([:positive])}")
             )
    end
  end

  defp repository!(id), do: OpenAgents.Repo.get!(OpenAgents.Repositories.Repository, id)
end
