defmodule OpenAgents.MilestonesTest do
  use OpenAgents.DataCase

  alias OpenAgents.Milestones

  describe "milestones" do
    alias OpenAgents.Milestones.Milestone

    import OpenAgents.MilestonesFixtures

    @invalid_attrs %{state: nil, description: nil, title: nil, number: nil, due_on: nil}

    test "list_milestones/0 returns all milestones" do
      milestone = milestone_fixture()
      assert Milestones.list_milestones() == [milestone]
    end

    test "get_milestone!/1 returns the milestone with given id" do
      milestone = milestone_fixture()
      assert Milestones.get_milestone!(milestone.id) == milestone
    end

    test "create_milestone/1 with valid data creates a milestone" do
      valid_attrs = %{
        state: "some state",
        description: "some description",
        title: "some title",
        number: 42,
        due_on: "some due_on"
      }

      assert {:ok, %Milestone{} = milestone} = Milestones.create_milestone(valid_attrs)
      assert milestone.state == "some state"
      assert milestone.description == "some description"
      assert milestone.title == "some title"
      assert milestone.number == 42
      assert milestone.due_on == "some due_on"
    end

    test "create_milestone/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Milestones.create_milestone(@invalid_attrs)
    end

    test "update_milestone/2 updates mutable fields but preserves its repository number" do
      milestone = milestone_fixture()

      update_attrs = %{
        state: "some updated state",
        description: "some updated description",
        title: "some updated title",
        number: 43,
        due_on: "some updated due_on"
      }

      assert {:ok, %Milestone{} = milestone} =
               Milestones.update_milestone(milestone, update_attrs)

      assert milestone.state == "some updated state"
      assert milestone.description == "some updated description"
      assert milestone.title == "some updated title"
      assert milestone.number == 42
      assert milestone.due_on == "some updated due_on"
    end

    test "update_milestone/2 with invalid data returns error changeset" do
      milestone = milestone_fixture()
      assert {:error, %Ecto.Changeset{}} = Milestones.update_milestone(milestone, @invalid_attrs)
      assert milestone == Milestones.get_milestone!(milestone.id)
    end

    test "delete_milestone/1 deletes the milestone" do
      milestone = milestone_fixture()
      assert {:ok, %Milestone{}} = Milestones.delete_milestone(milestone)
      assert_raise Ecto.NoResultsError, fn -> Milestones.get_milestone!(milestone.id) end
    end

    test "change_milestone/1 returns a milestone changeset" do
      milestone = milestone_fixture()
      assert %Ecto.Changeset{} = Milestones.change_milestone(milestone)
    end

    test "change_milestone/2 applies attrs and surfaces validation errors" do
      milestone = milestone_fixture()

      assert Milestones.change_milestone(milestone, %{title: "renamed"}).valid?

      changeset = Milestones.change_milestone(milestone, %{title: nil})
      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_milestone/1 assigns numbers from one upwards" do
      assert {:ok, %Milestone{number: 1}} =
               Milestones.create_milestone(%{title: "v1", state: "open"})

      assert {:ok, %Milestone{number: 2}} =
               Milestones.create_milestone(%{title: "v2", state: "open"})
    end

    test "create_milestone/1 honours an explicit number and continues from it" do
      assert {:ok, %Milestone{number: 10}} =
               Milestones.create_milestone(%{title: "v10", state: "open", number: 10})

      assert {:ok, %Milestone{number: 11}} =
               Milestones.create_milestone(%{title: "v11", state: "open"})
    end

    test "create_milestone/0 refuses an empty milestone" do
      assert {:error, %Ecto.Changeset{} = changeset} = Milestones.create_milestone()
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_milestone/1 accepts string keys" do
      assert {:ok, %Milestone{} = milestone} =
               Milestones.create_milestone(%{"title" => "v1", "state" => "open"})

      assert milestone.title == "v1"
      assert milestone.state == "open"
    end

    test "get_milestone_by_number!/1 returns the milestone with the given number" do
      milestone = milestone_fixture(number: 7)
      assert Milestones.get_milestone_by_number!(7) == milestone
    end

    test "get_milestone_by_number!/1 raises for an unknown number" do
      milestone_fixture(number: 7)
      assert_raise Ecto.NoResultsError, fn -> Milestones.get_milestone_by_number!(8) end
    end
  end
end
