defmodule OpenAgents.Forum.ActorLink do
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "forum_actor_links" do
    field :actor_ref, :string
    field :status, :string, default: "pending"
    field :proof_method, :string
    field :proof_evidence, :map
    field :linked_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec

    belongs_to :user, User, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :actor_ref,
      :user_id,
      :status,
      :proof_method,
      :proof_evidence,
      :linked_at,
      :rejected_at
    ])
    |> validate_required([:actor_ref, :user_id])
    |> unique_constraint([:actor_ref])
    |> unique_constraint([:user_id, :actor_ref])
    |> validate_inclusion(:status, ["pending", "linked", "rejected"])
  end
end
