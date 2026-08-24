defmodule OpenAgents.Forge.DeployReceipt do
  @moduledoc """
  Immutable terminal receipt for one fleet deployment attempt. The receipt
  binds the candidate to its deployment, artifact, manifest, expected member
  set, bounded per-node outcomes, rollback verification, and push-to-live
  duration. PostgreSQL rejects updates and deletes after insertion.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @results ~w(live reverted needs_rolling_replace failed)
  @deployment_types ~w(direct_load relup rolling_replacement)

  schema "forge_deploys" do
    field :repo, :string
    field :repository_id, :binary_id
    field :sha, :string
    field :target_id, :binary_id
    field :deployment_id, :binary_id
    field :artifact_digest, :string
    field :manifest_digest, :string
    field :modules, {:array, :string}, default: []
    field :nodes, {:array, :string}, default: []
    field :expected_nodes, {:array, :string}, default: []
    field :node_results, :map, default: %{}
    field :result, :string
    field :deployment_type, :string
    field :canary, :string
    field :error_code, :string
    field :rollback_verified, :boolean
    field :push_to_live_ms, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  @doc "All deploy results."
  def results, do: @results

  @doc "All deployment types."
  def deployment_types, do: @deployment_types

  def changeset(receipt, attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> default(:deployment_id, Ecto.UUID.generate())
      |> default(:started_at, now)
      |> default(:completed_at, now)

    receipt
    |> cast(attrs, [
      :repo,
      :repository_id,
      :sha,
      :target_id,
      :deployment_id,
      :artifact_digest,
      :manifest_digest,
      :modules,
      :nodes,
      :expected_nodes,
      :node_results,
      :result,
      :deployment_type,
      :canary,
      :error_code,
      :rollback_verified,
      :push_to_live_ms,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :repo,
      :sha,
      :target_id,
      :deployment_id,
      :result,
      :started_at,
      :completed_at
    ])
    |> validate_inclusion(:result, @results)
    |> validate_inclusion(:deployment_type, @deployment_types)
    |> validate_format(:sha, ~r/^[0-9a-f]{40}$/)
    |> validate_format(:artifact_digest, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:manifest_digest, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:modules, max: 2_048)
    |> validate_length(:nodes, max: 100)
    |> validate_length(:expected_nodes, max: 100)
    |> validate_length(:canary, max: 255)
    |> validate_length(:error_code, max: 128)
    |> validate_node_results()
    |> foreign_key_constraint(:repository_id)
    |> unique_constraint(:deployment_id)
    |> check_constraint(:result, name: :forge_deploys_result)
    |> check_constraint(:deployment_type, name: :forge_deploys_deployment_type)
    |> check_constraint(:artifact_digest, name: :forge_deploys_artifact_digest)
    |> check_constraint(:manifest_digest, name: :forge_deploys_manifest_digest)
    |> check_constraint(:node_results, name: :forge_deploys_node_bounds)
  end

  defp default(attrs, key, value) do
    cond do
      Map.has_key?(attrs, key) -> attrs
      Map.has_key?(attrs, to_string(key)) -> attrs
      true -> Map.put(attrs, key, value)
    end
  end

  defp validate_node_results(changeset) do
    validate_change(changeset, :node_results, fn :node_results, results ->
      valid? =
        is_map(results) and map_size(results) <= 100 and
          Enum.all?(results, fn {node, result} ->
            is_binary(node) and byte_size(node) in 1..255 and is_binary(result) and
              byte_size(result) in 1..255
          end)

      if valid?, do: [], else: [node_results: "must contain at most 100 bounded outcomes"]
    end)
  end
end
