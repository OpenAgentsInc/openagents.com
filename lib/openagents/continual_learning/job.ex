defmodule OpenAgents.ContinualLearning.Job do
  @moduledoc """
  One admitted continual-learning job.

  The row is the durable admission record: the named buyer, the versioned
  objective, the exact base model, the exact licensed dataset bindings, the
  evaluation inputs and evaluator policy, the budget, the runtime class with
  its capacity evidence, the stopping policy, and the digest over all of them.
  Identity never changes after admission; only lifecycle fields move.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued running completed failed interrupted budget_exhausted cancelled)
  @terminal_statuses ~w(completed failed interrupted budget_exhausted cancelled)
  @resumable_statuses ~w(interrupted budget_exhausted)
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "continual_learning_jobs" do
    field :buyer_ref, :string
    field :buyer_class, :string
    field :objective, :string
    field :objective_version, :integer
    field :base_model_ref, :string
    field :base_model_digest, :string
    field :training_code_digest, :string
    field :configuration, :map, default: %{}
    field :configuration_digest, :string
    field :datasets, {:array, :map}, default: []
    field :evaluation, :map, default: %{}
    field :budget, :map, default: %{}
    field :runtime_class, :string
    field :capacity_receipt, :map, default: %{}
    field :stopping_policy, :map, default: %{}
    field :admission_digest, :string
    field :status, :string, default: "queued"
    field :error_code, :string
    field :rounds_completed, :integer, default: 0
    field :resume_count, :integer, default: 0
    field :usage, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :work_job, OpenAgents.Work.Job
    belongs_to :replay_of, __MODULE__

    has_many :checkpoints, OpenAgents.ContinualLearning.Checkpoint, foreign_key: :job_id
    has_many :receipts, OpenAgents.ContinualLearning.Receipt, foreign_key: :job_id
    has_one :artifact, OpenAgents.ContinualLearning.Artifact, foreign_key: :job_id

    timestamps()
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses
  def resumable_statuses, do: @resumable_statuses

  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses
  def resumable?(%__MODULE__{status: status}), do: status in @resumable_statuses

  @doc "The immutable admission identity."
  def admission_changeset(job, attributes) do
    job
    |> cast(attributes, [
      :buyer_ref,
      :buyer_class,
      :objective,
      :objective_version,
      :base_model_ref,
      :base_model_digest,
      :training_code_digest,
      :configuration,
      :configuration_digest,
      :datasets,
      :evaluation,
      :budget,
      :runtime_class,
      :capacity_receipt,
      :stopping_policy,
      :admission_digest,
      :replay_of_id
    ])
    |> validate_required([
      :buyer_ref,
      :buyer_class,
      :objective,
      :objective_version,
      :base_model_ref,
      :base_model_digest,
      :training_code_digest,
      :configuration_digest,
      :evaluation,
      :budget,
      :runtime_class,
      :capacity_receipt,
      :stopping_policy,
      :admission_digest
    ])
    |> validate_length(:buyer_ref, min: 1, max: 256)
    |> validate_length(:buyer_class, min: 1, max: 128)
    |> validate_length(:objective, min: 1, max: 2_000)
    |> validate_number(:objective_version, greater_than: 0)
    |> validate_length(:base_model_ref, min: 1, max: 256)
    |> validate_format(:base_model_digest, @digest_regex)
    |> validate_format(:training_code_digest, @digest_regex)
    |> validate_format(:configuration_digest, @digest_regex)
    |> validate_format(:admission_digest, @digest_regex)
    |> validate_datasets()
    |> foreign_key_constraint(:replay_of_id)
  end

  @doc "Moves the job through its lifecycle without touching admission identity."
  def lifecycle_changeset(job, attributes) do
    job
    |> cast(attributes, [
      :status,
      :error_code,
      :rounds_completed,
      :resume_count,
      :usage,
      :work_job_id,
      :started_at,
      :completed_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:rounds_completed, greater_than_or_equal_to: 0)
    |> validate_number(:resume_count, greater_than_or_equal_to: 0)
    |> validate_length(:error_code, max: 128)
    |> unique_constraint(:work_job_id)
    |> foreign_key_constraint(:work_job_id)
  end

  defp validate_datasets(changeset) do
    datasets = get_field(changeset, :datasets) || []

    valid? =
      datasets != [] and
        Enum.all?(datasets, fn dataset ->
          is_map(dataset) and
            Enum.all?(
              ~w(listing_id acceptance_ref artifact_digest provenance_digest license_digest listing_digest),
              &match?(value when is_binary(value) and value != "", Map.get(dataset, &1))
            )
        end)

    if valid?,
      do: changeset,
      else: add_error(changeset, :datasets, "must bind at least one admitted licensed dataset")
  end
end
