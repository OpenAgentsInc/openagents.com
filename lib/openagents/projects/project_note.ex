defmodule OpenAgents.Projects.ProjectNote do
  @moduledoc """
  One entry in a project's discussion and activity record.

  A note carries project-wide context: why the project exists, the operating
  assumptions in force, and the decisions that apply across several issues.
  Issue comments stay on issues.

  Two kinds share the table and the ordering:

    * `"note"` is discussion an operator writes. Its author can edit and delete
      it.
    * `"activity"` is the immutable record of a project change, written by the
      context that made the change. Nothing edits or deletes it.

  The `repository_id` repeats the owning project's repository so the row is
  filtered through the same authority boundary every other project surface
  reads through, and a database constraint keeps the pair in agreement.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Projects.Project
  alias OpenAgents.Repositories.Repository

  @kinds ["note", "activity"]

  @doc "The note kinds, discussion first."
  def kinds, do: @kinds

  schema "project_notes" do
    field :body, :string
    field :kind, :string, default: "note"
    field :author, :map

    belongs_to :project, Project
    belongs_to :repository, Repository, type: :binary_id
    belongs_to :author_user, OpenAgents.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:body, :kind, :author, :project_id, :repository_id, :author_user_id])
    |> update_change(:body, &trim/1)
    |> validate_required([:body, :kind, :project_id, :repository_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:body, max: 20_000)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:author_user_id)
    |> foreign_key_constraint(:project_id, name: :project_notes_project_repository_fkey)
    |> check_constraint(:kind, name: :project_notes_kind_check)
  end

  defp trim(body) when is_binary(body), do: String.trim(body)
  defp trim(body), do: body
end
