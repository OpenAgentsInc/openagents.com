defmodule OpenAgents.Repositories.RepositoryImport do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "repository_imports" do
    field :provider, :string, default: "github"
    field :source_repository_id, :integer
    field :source_owner_id, :integer
    field :source_full_name, :string
    field :source_default_branch, :string
    field :source_ref_digest, :string
    field :source_head_sha, :string
    field :source_refs, :map
    field :source_uses_lfs, :boolean, default: false
    field :state, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :error_code, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :repository, OpenAgents.Repositories.Repository
    timestamps()
  end

  def changeset(repository_import, repository_id, attrs) do
    repository_import
    |> cast(attrs, [
      :provider,
      :source_repository_id,
      :source_owner_id,
      :source_full_name,
      :source_default_branch,
      :source_ref_digest,
      :source_head_sha,
      :source_refs,
      :source_uses_lfs
    ])
    |> put_change(:repository_id, repository_id)
    |> put_change(:provider, "github")
    |> put_change(:state, "pending")
    |> put_change(:attempt_count, 0)
    |> validate_required([
      :repository_id,
      :provider,
      :source_repository_id,
      :source_owner_id,
      :source_full_name,
      :source_default_branch,
      :source_ref_digest,
      :source_refs,
      :state
    ])
    |> validate_number(:source_repository_id, greater_than: 0)
    |> validate_number(:source_owner_id, greater_than: 0)
    |> validate_length(:source_full_name, min: 3, max: 202)
    |> validate_length(:source_default_branch, min: 1, max: 255)
    |> validate_format(:source_ref_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:source_head_sha, ~r/\A[0-9a-f]{40,64}\z/)
    |> validate_ref_map()
    |> unique_constraint(:repository_id)
    |> foreign_key_constraint(:repository_id)
    |> check_constraint(:state, name: :repository_imports_state_check)
    |> check_constraint(:source_ref_digest, name: :repository_imports_digest_check)
  end

  def transition_changeset(repository_import, attrs) do
    repository_import
    |> cast(attrs, [:state, :attempt_count, :error_code, :started_at, :completed_at])
    |> validate_required([:state, :attempt_count])
    |> validate_inclusion(:state, ~w(pending running completed failed))
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_length(:error_code, max: 80)
    |> check_constraint(:state, name: :repository_imports_state_check)
  end

  defp validate_ref_map(changeset) do
    validate_change(changeset, :source_refs, fn :source_refs, refs ->
      valid? =
        is_map(refs) and map_size(refs) <= 10_000 and
          Enum.all?(refs, fn
            {"refs/heads/" <> name, sha} -> valid_ref_part?(name) and valid_sha?(sha)
            {"refs/tags/" <> name, sha} -> valid_ref_part?(name) and valid_sha?(sha)
            _invalid -> false
          end)

      if valid?, do: [], else: [source_refs: "must contain bounded branch and tag refs"]
    end)
  end

  defp valid_ref_part?(name),
    do: name != "" and byte_size(name) <= 255 and not String.contains?(name, "..")

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, sha)
end
