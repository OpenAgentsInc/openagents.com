defmodule OpenAgents.Inference.Grant do
  @moduledoc """
  A fenced inference grant (`sarah.inference_grant.v1`).

  Authority for one bounded body of work to call the Sarah inference proxy,
  metered against the owner's account. It is **not** a provider credential: the
  OpenAI key never leaves the server (RELEASE-002). A grant is budgeted (tokens
  / calls / estimated cost), time-bounded, and revocable. Only the token digest
  is stored; the plaintext is returned once at mint and injected into the probe
  process by the controller at spawn.

  Every grant names exactly one fence — a thread or a conversation, never both
  and never neither (THREAD-001). The conversation fence is the original one
  and is unchanged; the thread fence is what lets a coding session reach a
  model without borrowing the account's single conversation.
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
    field :thread_id, :binary_id
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
      :thread_id,
      :machine_id,
      :model_id,
      :token_digest,
      :max_total_tokens,
      :max_calls,
      :max_cost_microusd,
      :expires_at
    ])
    # machine_id is nil for Sarah-internal grants (a coding job metering its
    # own runtime, #122); computer-bound probe delegations always set it.
    # `expires_at` is cast but not required: nil is a grant with no clock. A
    # thread's authority is bounded by budget and revocation, not by how long
    # the reader has been working. A computer-bound delegation still sets one,
    # where the deadline is a security bound rather than a convenience.
    |> validate_required([
      :owner_visitor_id,
      :model_id,
      :token_digest,
      :max_total_tokens,
      :max_calls,
      :max_cost_microusd
    ])
    |> validate_number(:max_total_tokens, greater_than: 0)
    |> validate_number(:max_calls, greater_than: 0)
    |> validate_number(:max_cost_microusd, greater_than: 0)
    |> validate_exactly_one_fence()
    |> unique_constraint(:token_digest)
    |> unique_constraint(:thread_id, name: :inference_grants_one_active_thread_index)
    |> check_constraint(:conversation_id, name: :inference_grant_exactly_one_fence)
  end

  # A grant with no fence is unattributable spend; a grant with two is spend
  # attributed twice. PostgreSQL refuses both independently
  # (`inference_grant_exactly_one_fence`); this is the same refusal, earlier.
  defp validate_exactly_one_fence(changeset) do
    case {get_field(changeset, :conversation_id), get_field(changeset, :thread_id)} do
      {conversation_id, nil} when is_binary(conversation_id) ->
        changeset

      {nil, thread_id} when is_binary(thread_id) ->
        changeset

      _neither_or_both ->
        add_error(changeset, :thread_id, "must name exactly one thread or conversation")
    end
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
