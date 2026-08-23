defmodule OpenAgents.Deployments.WorkflowGrant do
  @moduledoc """
  A short-lived credential a workflow run holds to act on one repository.

  The grant binds a repository, an optional environment, the source ref and
  workflow it was issued for, and the exact workflow run it belongs to. Only the
  token digest is stored. The grant cannot widen: authorization compares the
  request against these bound values rather than against anything the caller
  sends.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @scopes ~w(deployments:request deployments:checks)
  @maximum_lifetime_seconds 3_600

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "deployment_workflow_grants" do
    field :token_digest, :string
    field :audience, :string
    field :source_ref, :string
    field :source_workflow, :string
    field :workflow_run_id, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :environment, OpenAgents.Deployments.Environment
    belongs_to :created_by_user, OpenAgents.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:audience, :source_ref, :source_workflow, :workflow_run_id, :scopes])
    |> validate_required([
      :token_digest,
      :audience,
      :source_ref,
      :source_workflow,
      :workflow_run_id,
      :expires_at
    ])
    |> validate_length(:audience, min: 1, max: 120)
    |> validate_length(:source_ref, min: 1, max: 255)
    |> validate_length(:source_workflow, min: 1, max: 120)
    |> validate_length(:workflow_run_id, min: 1, max: 64)
    |> validate_scopes()
    |> validate_lifetime()
    |> unique_constraint(:token_digest)
  end

  @doc "The scopes a workflow grant can carry."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "The longest lifetime a grant may be issued for."
  @spec maximum_lifetime_seconds() :: pos_integer()
  def maximum_lifetime_seconds, do: @maximum_lifetime_seconds

  @doc "Whether the grant is usable at `now`."
  @spec usable?(t(), DateTime.t()) :: boolean()
  def usable?(%__MODULE__{} = grant, %DateTime{} = now) do
    is_nil(grant.revoked_at) and DateTime.compare(grant.expires_at, now) == :gt
  end

  defp validate_scopes(changeset) do
    validate_change(changeset, :scopes, fn :scopes, scopes ->
      cond do
        scopes == [] -> [scopes: "must name at least one scope"]
        Enum.any?(scopes, &(&1 not in @scopes)) -> [scopes: "contains an unknown scope"]
        true -> []
      end
    end)
  end

  defp validate_lifetime(changeset) do
    expires_at = get_field(changeset, :expires_at)

    if is_nil(expires_at) or
         DateTime.diff(expires_at, DateTime.utc_now()) <= @maximum_lifetime_seconds do
      changeset
    else
      add_error(changeset, :expires_at, "exceeds the maximum grant lifetime")
    end
  end
end
