defmodule OpenAgents.ContinualLearning.Artifact do
  @moduledoc """
  The terminal model artifact of one continual-learning job.

  The artifact digest is taken over the exact base model, the exact licensed
  dataset bindings, the exact training code, the exact configuration, the
  ordered checkpoint chain, and the exact evaluation inputs and results, so a
  reader can reproduce the identity of what was produced without trusting the
  producer.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "continual_learning_artifacts" do
    belongs_to :job, OpenAgents.ContinualLearning.Job
    field :model_ref, :string
    field :model_digest, :string
    field :base_model_digest, :string
    field :training_code_digest, :string
    field :configuration_digest, :string
    field :dataset_bindings, {:array, :map}, default: []
    field :checkpoint_digests, {:array, :string}, default: []
    field :evaluation_result, :map, default: %{}
    field :accepted_outcome, :map, default: %{}
    field :settlement, :map, default: %{}
    field :artifact_digest, :string

    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(artifact, attributes) do
    artifact
    |> cast(attributes, [
      :model_ref,
      :model_digest,
      :base_model_digest,
      :training_code_digest,
      :configuration_digest,
      :dataset_bindings,
      :checkpoint_digests,
      :evaluation_result,
      :accepted_outcome,
      :settlement,
      :artifact_digest
    ])
    |> validate_required([
      :model_ref,
      :model_digest,
      :base_model_digest,
      :training_code_digest,
      :configuration_digest,
      :evaluation_result,
      :accepted_outcome,
      :artifact_digest
    ])
    |> validate_format(:model_digest, @digest_regex)
    |> validate_format(:base_model_digest, @digest_regex)
    |> validate_format(:training_code_digest, @digest_regex)
    |> validate_format(:configuration_digest, @digest_regex)
    |> validate_format(:artifact_digest, @digest_regex)
    |> validate_checkpoint_chain()
    |> unique_constraint(:job_id)
    |> unique_constraint(:artifact_digest)
    |> foreign_key_constraint(:job_id)
  end

  defp validate_checkpoint_chain(changeset) do
    digests = get_field(changeset, :checkpoint_digests) || []

    if digests != [] and Enum.all?(digests, &Regex.match?(@digest_regex, &1)) do
      changeset
    else
      add_error(changeset, :checkpoint_digests, "must name the ordered checkpoint chain")
    end
  end
end
