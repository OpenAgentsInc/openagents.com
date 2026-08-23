defmodule OpenAgents.Deployments.CheckResult do
  @moduledoc """
  A published check result bound to the exact bytes it examined.

  Identity is `{repository, name, commit, artifact digest}`. Publishing the same
  check name for a different commit or artifact writes a new row rather than
  relabelling old evidence, so a green result cannot be replayed onto bytes it
  never ran against.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending succeeded failed)
  @commit_pattern ~r/\A[0-9a-f]{40}\z/
  @artifact_pattern ~r/\A[a-z0-9]+:[0-9a-f]{32,89}\z/

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "deployment_check_results" do
    field :name, :string
    field :commit_sha, :string
    field :artifact_digest, :string
    field :status, :string
    field :evidence_url, :string
    field :evidence_digest, :string
    field :valid_until, :utc_datetime_usec
    field :published_by_grant_id, :binary_id

    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :published_by_user, OpenAgents.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(check_result, attrs) do
    check_result
    |> cast(attrs, [
      :name,
      :commit_sha,
      :artifact_digest,
      :status,
      :evidence_url,
      :evidence_digest,
      :valid_until
    ])
    |> validate_required([:name, :commit_sha, :artifact_digest, :status])
    |> update_change(:commit_sha, &String.downcase/1)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_format(:commit_sha, @commit_pattern)
    |> validate_format(:artifact_digest, @artifact_pattern)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:evidence_url, max: 500)
    |> validate_evidence_url()
    |> validate_format(:evidence_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:name, name: :deployment_check_results_identity_index)
  end

  @doc "The statuses a check result can hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  # Evidence is a link the tenant reads back, so only plain HTTPS is stored: a
  # credentialed or non-HTTP URL in a durable record is a leak, not a link.
  defp validate_evidence_url(changeset) do
    validate_change(changeset, :evidence_url, fn :evidence_url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) -> []
        _invalid -> [evidence_url: "must be an https URL without credentials"]
      end
    end)
  end
end
