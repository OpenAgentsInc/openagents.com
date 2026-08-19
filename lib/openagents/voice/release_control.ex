defmodule OpenAgents.Voice.ReleaseControl do
  @moduledoc "Append-only operational admission authority for new voice sessions."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias OpenAgents.Repo

  @states ~w(open draining disabled)
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_release_controls" do
    field :state, :string
    field :reason, :string
    field :actor, :string
    field :source_revision, :string
    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          state: String.t() | nil,
          reason: String.t() | nil,
          actor: String.t() | nil,
          source_revision: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  def changeset(control, attributes) do
    control
    |> cast(attributes, [:state, :reason, :actor, :source_revision])
    |> validate_required([:state, :reason, :actor, :source_revision])
    |> validate_inclusion(:state, @states)
    |> validate_length(:reason, min: 1, max: 500)
    |> validate_length(:actor, min: 1, max: 128)
    |> validate_length(:source_revision, min: 1, max: 128)
  end

  @spec current!() :: t()
  def current! do
    Repo.one!(
      from(control in __MODULE__,
        order_by: [desc: control.inserted_at, desc: control.id],
        limit: 1
      )
    )
  end

  @spec lock_current!() :: t()
  def lock_current! do
    Repo.one!(
      from(control in __MODULE__,
        order_by: [desc: control.inserted_at, desc: control.id],
        limit: 1,
        lock: "FOR SHARE"
      )
    )
  end

  @spec append(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def append(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> changeset(attributes)
    |> Repo.insert()
  end

  @spec require_open(t()) :: :ok | {:error, :voice_draining | :voice_disabled}
  def require_open(%__MODULE__{state: "open"}), do: :ok
  def require_open(%__MODULE__{state: "draining"}), do: {:error, :voice_draining}
  def require_open(%__MODULE__{state: "disabled"}), do: {:error, :voice_disabled}
end
