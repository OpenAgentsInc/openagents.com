defmodule OpenAgents.Forge.Target do
  @moduledoc """
  Ecto schema for `forge_fleet_targets`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(promoted building built deploying live reverted needs_relup needs_rolling_replace failed)

  schema "forge_fleet_targets" do
    field :repo, :string
    field :sha, :string
    field :promoted_by, :string
    field :strategy, :string
    field :status, :string, default: "promoted"
    field :details, :map, default: %{}

    timestamps()
  end

  def changeset(target, attrs) do
    target
    |> cast(attrs, [:repo, :sha, :promoted_by, :strategy, :status, :details])
    |> validate_required([:repo, :sha, :promoted_by, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:repo, max: 500)
    |> validate_length(:sha, max: 64)
    |> validate_length(:promoted_by, max: 200)
    |> validate_length(:strategy, max: 64)
    |> validate_details()
  end

  defp validate_details(changeset) do
    validate_change(changeset, :details, fn :details, details ->
      cond do
        not is_map(details) ->
          [details: "must be a map"]

        map_size(details) > 100 ->
          [details: "exceeds the 100-key bound"]

        string_size(details) > 32_000 ->
          [details: "exceeds the 32KB bound"]

        true ->
          []
      end
    end)
  end

  defp string_size(value) when is_binary(value), do: byte_size(value)
  defp string_size(value) when is_list(value), do: length(value)

  defp string_size(value) when is_map(value),
    do: Enum.reduce(value, 0, fn {k, v}, acc -> acc + string_size(k) + string_size(v) end)

  defp string_size(_), do: 0
end
