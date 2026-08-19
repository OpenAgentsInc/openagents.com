defmodule OpenAgents.Modules.LifecycleReceipt do
  @moduledoc "Append-only operator receipt controlling selection in future registry captures."

  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(stage admit deprecate disable revoke rollback)
  @states ~w(staged admitted deprecated disabled revoked)
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "module_lifecycle_receipts" do
    field :module_id, :string
    field :module_version, :integer
    field :generation, :integer
    field :action, :string
    field :from_state, :string
    field :to_state, :string
    field :base_artifact_digest, :string
    field :resulting_artifact_digest, :string
    field :base_registry_digest, :string
    field :resulting_registry_digest, :string
    field :actor_id, :string
    field :auth_method, :string
    field :approval_receipt_ref, :string
    field :reason, :string
    field :predecessor, :map
    field :deprecation, :map
    field :dependent_refs, {:array, :string}, default: []
    timestamps()
  end

  @type t :: %__MODULE__{}

  def create_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :module_id,
      :module_version,
      :generation,
      :action,
      :from_state,
      :to_state,
      :base_artifact_digest,
      :resulting_artifact_digest,
      :base_registry_digest,
      :resulting_registry_digest,
      :actor_id,
      :auth_method,
      :approval_receipt_ref,
      :reason,
      :predecessor,
      :deprecation,
      :dependent_refs
    ])
    |> validate_required([
      :module_id,
      :module_version,
      :generation,
      :action,
      :from_state,
      :to_state,
      :base_artifact_digest,
      :resulting_artifact_digest,
      :base_registry_digest,
      :resulting_registry_digest,
      :actor_id,
      :auth_method,
      :approval_receipt_ref,
      :reason
    ])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:from_state, @states)
    |> validate_inclusion(:to_state, @states)
    |> validate_number(:module_version, greater_than: 0)
    |> validate_number(:generation, greater_than: 0)
    |> validate_length(:module_id, min: 1, max: 128)
    |> validate_length(:actor_id, min: 1, max: 256)
    |> validate_length(:auth_method, min: 1, max: 128)
    |> validate_length(:approval_receipt_ref, min: 1, max: 256)
    |> validate_length(:reason, min: 1, max: 1_000)
    |> validate_format(:base_artifact_digest, @digest_regex)
    |> validate_format(:resulting_artifact_digest, @digest_regex)
    |> validate_format(:base_registry_digest, @digest_regex)
    |> validate_format(:resulting_registry_digest, @digest_regex)
    |> validate_refs()
    |> unique_constraint([:module_id, :module_version, :generation])
    |> unique_constraint(:approval_receipt_ref)
  end

  defp validate_refs(changeset) do
    validate_change(changeset, :dependent_refs, fn :dependent_refs, refs ->
      if is_list(refs) and length(refs) <= 64 and
           Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..256)),
         do: [],
         else: [dependent_refs: "must contain bounded module references"]
    end)
  end
end
