defmodule OpenAgents.PullRequests.PullRequest do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pull_requests" do
    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :issue, OpenAgents.Issues.Issue, type: :id
    belongs_to :head_repository, OpenAgents.Repositories.Repository
    field :head_ref, :string
    field :head_sha, :string
    field :base_ref, :string
    field :base_sha, :string
    field :state, :string, default: "open"
    field :draft, :boolean, default: true
    belongs_to :repository_publication, OpenAgents.Repositories.RepositoryPublication
    belongs_to :opened_by_user, OpenAgents.Accounts.User
    field :conversation_id, :binary_id
    field :merged_at, :utc_datetime_usec
    belongs_to :merged_by_user, OpenAgents.Accounts.User
    field :merge_commit_sha, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pull_request, attrs) do
    pull_request
    |> cast(attrs, [
      :head_ref,
      :head_sha,
      :base_ref,
      :base_sha,
      :state,
      :draft,
      :conversation_id
    ])
    |> put_programmatic_change(attrs, :repository_id)
    |> put_programmatic_change(attrs, :issue_id)
    |> put_programmatic_change(attrs, :head_repository_id)
    |> put_programmatic_change(attrs, :repository_publication_id)
    |> put_programmatic_change(attrs, :opened_by_user_id)
    |> validate_required([
      :repository_id,
      :issue_id,
      :head_repository_id,
      :head_ref,
      :head_sha,
      :base_ref,
      :base_sha
    ])
    |> validate_length(:head_ref, min: 1, max: 255)
    |> validate_length(:base_ref, min: 1, max: 255)
    |> validate_inclusion(:state, ~w(open closed))
    |> unique_constraint(:issue_id)
    |> unique_constraint(:repository_publication_id)
    |> unique_constraint([:repository_id, :head_repository_id, :head_ref, :base_ref],
      name: :pull_requests_one_open_head_base_index
    )
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:head_repository_id)
  end

  defp put_programmatic_change(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> put_string_key_change(changeset, attrs, field)
    end
  end

  defp put_string_key_change(changeset, attrs, field) do
    case Map.fetch(attrs, Atom.to_string(field)) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
