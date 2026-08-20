defmodule OpenAgents.Forge.DeployReceipt do
  @moduledoc """
  Receipt for one hot-deploy attempt (`forge_deploys`, roadmap P4): what was
  loaded (or refused), on which nodes, with the canary outcome and the
  first-class **push→live duration** measured from the matching push receipt.
  Every outcome is receipted — `live`, `reverted`, `needs_rolling_replace`,
  and `failed` alike — so the deploy lane never fails silently.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @results ~w(live reverted needs_rolling_replace failed)

  schema "forge_deploys" do
    field :repo, :string
    field :sha, :string
    field :target_id, :id
    field :modules, {:array, :string}, default: []
    field :nodes, {:array, :string}, default: []
    field :result, :string
    field :canary, :string
    field :push_to_live_ms, :integer
    timestamps(updated_at: false)
  end

  @doc "All deploy results."
  def results, do: @results

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :repo,
      :sha,
      :target_id,
      :modules,
      :nodes,
      :result,
      :canary,
      :push_to_live_ms
    ])
    |> validate_required([:repo, :sha, :target_id, :result])
    |> validate_inclusion(:result, @results)
    |> check_constraint(:result, name: :forge_deploys_result)
  end
end
