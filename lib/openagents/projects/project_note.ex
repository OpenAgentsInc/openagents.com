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

  alias OpenAgents.ContentVault
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repositories.Repository

  @kinds ["note", "activity"]
  @scope "project_notes.body"

  @doc "The note kinds, discussion first."
  def kinds, do: @kinds

  schema "project_notes" do
    field :body, :string, redact: true
    field :body_ciphertext, :binary, redact: true
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
    |> validate_required([:kind, :project_id, :repository_id])
    |> validate_body_present()
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:body, max: 20_000)
    |> seal_body()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:author_user_id)
    |> foreign_key_constraint(:project_id, name: :project_notes_project_repository_fkey)
    |> check_constraint(:kind, name: :project_notes_kind_check)
  end

  @doc "The column this schema's sealed body belongs to."
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc """
  The note body, opened from the seal.

  Falls back to the plaintext column for a row an un-replaced node wrote during
  a rolling replacement, and returns `nil` when neither can be read so a
  project page renders one missing note rather than failing whole.
  """
  @spec text(%__MODULE__{}) :: String.t() | nil
  def text(%__MODULE__{body_ciphertext: sealed} = note) when is_binary(sealed),
    do: ContentVault.text(sealed, @scope, seal_binding(note))

  def text(%__MODULE__{body: body}), do: body

  @doc """
  The row identity a sealed body is bound to.

  The primary key is a sequence, so it does not exist while the insert is
  being built. What does exist, and never changes afterwards, is the note's
  place: an edit rewrites the body, never the project, the repository, or the
  kind. Binding to those is what stops a sealed note from being lifted into
  another project and still opening.
  """
  @spec seal_binding(%__MODULE__{}) :: ContentVault.binding()
  def seal_binding(%__MODULE__{} = note), do: [note.project_id, note.repository_id, note.kind]

  # An edit that changes only the kind or the author leaves `body` unchanged,
  # and the stored plaintext is now `nil` because the body rests sealed. So
  # "a note has a body" is asked of both halves rather than of the column the
  # contract migration is going to drop.
  defp validate_body_present(changeset) do
    if get_field(changeset, :body) || get_field(changeset, :body_ciphertext),
      do: changeset,
      else: add_error(changeset, :body, "can't be blank", validation: :required)
  end

  defp seal_body(%Ecto.Changeset{valid?: true} = changeset) do
    case get_change(changeset, :body) do
      nil ->
        changeset

      body ->
        binding = [
          get_field(changeset, :project_id),
          get_field(changeset, :repository_id),
          get_field(changeset, :kind)
        ]

        case ContentVault.seal(body, @scope, binding) do
          {:ok, sealed} ->
            changeset
            |> put_change(:body_ciphertext, sealed)
            |> force_change(:body, nil)

          {:error, reason} ->
            add_error(changeset, :body, "cannot be sealed", reason: reason)
        end
    end
  end

  defp seal_body(changeset), do: changeset

  defp trim(body) when is_binary(body), do: String.trim(body)
  defp trim(body), do: body
end
