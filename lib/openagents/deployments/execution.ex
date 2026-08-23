defmodule OpenAgents.Deployments.Execution do
  @moduledoc """
  The immutable, fully admitted work a provider is handed.

  An execution is built only after policy admitted the run, and it carries no
  caller authority: no token, no membership, no scope. A provider that is
  compromised can therefore misreport its own deployment, but cannot deploy to
  another environment or read another repository.

  Resolved secret values live here and only here, for the duration of one
  attempt. The struct redacts them from `inspect/1` so a crash report, a logger
  metadata dump, or an exception message cannot carry a tenant credential.
  """

  @derive {Inspect, except: [:secrets]}

  @enforce_keys [
    :run_id,
    :repository,
    :environment,
    :commit_sha,
    :artifact_digest,
    :input_digest,
    :attempt,
    :deadline
  ]
  defstruct [
    :run_id,
    :repository,
    :environment,
    :commit_sha,
    :artifact_digest,
    :input_digest,
    :attempt,
    :deadline,
    provider_config: %{},
    secrets: %{}
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          repository: String.t(),
          environment: String.t(),
          commit_sha: String.t(),
          artifact_digest: String.t(),
          input_digest: String.t(),
          attempt: pos_integer(),
          deadline: DateTime.t(),
          provider_config: map(),
          secrets: %{optional(String.t()) => String.t()}
        }

  @doc "Whether the execution's deadline has passed at `now`."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{} = execution, %DateTime{} = now),
    do: DateTime.compare(now, execution.deadline) != :lt

  defimpl Jason.Encoder do
    # Executions are never serialized with their secrets. Encoding exists for
    # bounded diagnostics, so it emits identities only.
    def encode(execution, opts) do
      Jason.Encode.map(
        %{
          "run_id" => execution.run_id,
          "repository" => execution.repository,
          "environment" => execution.environment,
          "commit_sha" => execution.commit_sha,
          "artifact_digest" => execution.artifact_digest,
          "input_digest" => execution.input_digest,
          "attempt" => execution.attempt
        },
        opts
      )
    end
  end
end
