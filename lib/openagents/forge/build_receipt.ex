defmodule OpenAgents.Forge.BuildReceipt do
  @moduledoc """
  Durable record of one uniquely identified build attempt in the forge deploy
  lane (`forge_builds`). The row exists before the sidecar receives work and
  advances through `running` to `complete`, `failed`, or `expired`. A process
  restart expires the abandoned build ID before creating a new attempt, so a
  late response can never be mistaken for the retry.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "forge_builds" do
    field :repo, :string
    field :sha, :string
    field :target_id, :binary_id
    field :status, :string, default: "running"
    field :baseline_manifest, :map
    field :manifest, :map
    field :modules, {:array, :string}, default: []
    field :warnings, :string
    field :tests, :string
    field :duration_ms, :integer
    field :artifact, :string
    field :artifact_digest, :string
    field :output_digest, :string
    field :output_ref, :string
    field :error_code, :string
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  @doc "Create the durable `running` row before handing work to the sidecar."
  def start_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:repo, :sha, :target_id, :baseline_manifest])
    |> put_change(:status, "running")
    |> validate_required([:repo, :sha, :target_id, :status])
    |> validate_format(:sha, ~r/^[0-9a-f]{40}$/)
    |> unique_constraint(:target_id, name: :forge_builds_one_running_attempt_per_target)
  end

  @doc "Complete a running attempt with its immutable verified manifest."
  def complete_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :manifest,
      :modules,
      :warnings,
      :tests,
      :duration_ms,
      :artifact,
      :artifact_digest,
      :output_digest,
      :output_ref
    ])
    |> put_change(:status, "complete")
    |> put_change(:completed_at, DateTime.utc_now())
    |> validate_required([:manifest, :modules, :artifact, :artifact_digest, :duration_ms])
    |> validate_format(:artifact_digest, ~r/^[0-9a-f]{64}$/)
    |> validate_optional_digest(:output_digest)
  end

  @doc "Close a running attempt as failed or expired."
  def terminal_changeset(receipt, status, attrs) when status in ~w(failed expired) do
    receipt
    |> cast(attrs, [:warnings, :duration_ms, :output_digest, :output_ref, :error_code])
    |> put_change(:status, status)
    |> put_change(:completed_at, DateTime.utc_now())
    |> validate_required([:error_code])
    |> validate_format(:error_code, ~r/^[a-z0-9_]{1,128}$/)
    |> validate_optional_digest(:output_digest)
  end

  # Compatibility for receipt fixtures and changelog tests. Runtime builds use
  # the explicit lifecycle changesets above.
  def changeset(receipt, attrs) do
    status = Map.get(attrs, :status, Map.get(attrs, "status", "complete"))

    receipt
    |> cast(attrs, [
      :repo,
      :sha,
      :target_id,
      :status,
      :baseline_manifest,
      :manifest,
      :modules,
      :warnings,
      :tests,
      :duration_ms,
      :artifact,
      :artifact_digest,
      :output_digest,
      :output_ref,
      :error_code,
      :completed_at
    ])
    |> put_change(:status, status)
    |> validate_required([:repo, :sha, :target_id])
    |> validate_inclusion(:status, ~w(running complete failed expired))
  end

  defp validate_optional_digest(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> validate_format(changeset, field, ~r/^[0-9a-f]{64}$/)
    end
  end
end
