defmodule OpenAgents.Forge.Target do
  @moduledoc """
  One fleet-target promotion (`forge_fleet_targets`): the operator-approved
  commit the fleet should converge to, with its deploy-lane status and
  bounded per-step details. Append-only per repo; newest row = current.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "forge_fleet_targets" do
    field :repo, :string
    field :sha, :string
    field :promoted_by, :string
    field :status, :string, default: "promoted"
    field :details, :map, default: %{}
    timestamps()
  end

  def changeset(target, attrs) do
    target
    |> cast(attrs, [:repo, :sha, :promoted_by, :status, :details])
    |> validate_required([:repo, :sha, :promoted_by, :status])
    |> validate_details()
    |> check_constraint(:status, name: :forge_fleet_target_status)
  end

  defp validate_details(changeset) do
    validate_change(changeset, :details, fn :details, details ->
      details = details || %{}
      errors = []

      errors =
        if map_size(details) > 100,
          do: [{:details, {"exceeds the 100-key bound", []}} | errors],
          else: errors

      errors =
        if Enum.any?(details, fn {_k, v} -> is_binary(v) and byte_size(v) > 32_768 end) do
          [{:details, {"exceeds the 32KB bound", []}} | errors]
        else
          errors
        end

      errors
    end)
  end

  def status_changeset(target, status, details) do
    target
    |> change(%{status: status, details: Map.merge(target.details || %{}, details)})
    |> check_constraint(:status, name: :forge_fleet_target_status)
  end
end
