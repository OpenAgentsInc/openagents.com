defmodule OpenAgents.Agents.Agent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agents" do
    field :handle, :string
    field :display_name, :string
    field :description, :string
    field :status, :string, default: "active"
    field :suspended_at, :utc_datetime_usec
    field :suspension_reason, :string
    field :registration_ip_digest, :binary, redact: true

    has_many :tokens, OpenAgents.Agents.AgentToken
    has_many :user_links, OpenAgents.Agents.AgentUserLink

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :handle,
      :display_name,
      :description,
      :status,
      :suspended_at,
      :suspension_reason,
      :registration_ip_digest
    ])
    |> validate_required([:handle, :display_name, :registration_ip_digest])
    |> validate_length(:handle, min: 3, max: 39)
    |> validate_length(:display_name, min: 1, max: 255)
    |> validate_length(:description, max: 4_000)
    |> validate_inclusion(:status, ["active", "suspended"])
    |> unique_constraint(:handle, name: :agents_lower_handle_index)
    |> check_constraint(:handle, name: :agents_handle_check)
    |> check_constraint(:status, name: :agents_status_check)
  end
end
