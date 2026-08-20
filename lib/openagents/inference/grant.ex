defmodule OpenAgents.Inference.Grant do
  @moduledoc """
  A delegation-scoped inference grant (`sarah.inference_grant.v1`).

  Authority for one paired-machine coding delegation to call the Sarah
  inference proxy, metered against the owner's account. It is **not** a
  provider credential: the OpenAI key never leaves the server (RELEASE-002).
  A grant is generation-fenced by its conversation, budgeted (tokens / calls
  / estimated cost), time-bounded, and revocable. Only the token digest is
  stored; the plaintext is returned once at mint and injected into the probe
  process by the controller at spawn.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(active exhausted revoked expired)
  @terminal_statuses ~w(exhausted revoked expired)

  @type t :: %__MODULE__{}

  schema "inference_grants" do
    field :owner_visitor_id, :binary_id
    field :conversation_id, :binary_id
    field :machine_id, :binary_id
    field :model_id, :string
    field :token_digest, :binary, redact: true
    field :status, :string, default: "active"

    field :max_total_tokens, :integer
    field :max_calls, :integer
    field :max_cost_microusd, :integer

    field :call_count, :integer, default: 0
    field :usage, :map, default: %{}

    field :expires_at, :utc_datetime_usec
    field :exhausted_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  @doc "The immutable capture at mint time."
  def mint_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :owner_visitor_id,
      :conversation_id,
      :machine_id,
      :model_id,
      :token_digest,
      :max_total_tokens,
      :max_calls,
      :max_cost_microusd,
      :expires_at
    ])
    # machine_id is nil for Sarah-internal grants (a coding job metering its
    # own runtime, #122); machine-bound probe delegations always set it.
    |> validate_required([
      :owner_visitor_id,
      :conversation_id,
      :model_id,
      :token_digest,
      :max_total_tokens,
      :max_calls,
      :max_cost_microusd,
      :expires_at
    ])
    |> validate_number(:max_total_tokens, greater_than: 0)
    |> validate_number(:max_calls, greater_than: 0)
    |> validate_number(:max_cost_microusd, greater_than: 0)
    |> unique_constraint(:token_digest)
  end

  @doc "Record one metered call: forward-only usage/count, terminal on budget."
  def usage_changeset(%__MODULE__{} = grant, usage, next_status, now) do
    grant
    |> change(%{
      usage: usage,
      call_count: grant.call_count + 1,
      status: next_status
    })
    |> maybe_stamp_terminal(next_status, now)
    |> check_constraint(:status, name: :inference_grant_status)
  end

  @doc "Terminal transition without a metered call (revoke, expire)."
  def terminal_changeset(%__MODULE__{} = grant, status, now) when status in @terminal_statuses do
    grant
    |> change(%{status: status})
    |> maybe_stamp_terminal(status, now)
    |> check_constraint(:status, name: :inference_grant_status)
  end

  defp maybe_stamp_terminal(changeset, "revoked", now),
    do: put_change(changeset, :revoked_at, now)

  defp maybe_stamp_terminal(changeset, "exhausted", now),
    do: put_change(changeset, :exhausted_at, now)

  defp maybe_stamp_terminal(changeset, "expired", now),
    do: put_change(changeset, :exhausted_at, now)

  defp maybe_stamp_terminal(changeset, _active, _now), do: changeset

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses
end
