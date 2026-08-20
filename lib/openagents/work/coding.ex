defmodule OpenAgents.Work.Coding do
  @moduledoc """
  The coding job kind's lifecycle edges (#122, SELF-EDIT-001): role and
  authority selection for the JobServer loop, per-job workspace cleanup, and
  metering the job's inference usage into the same grant ledger as everyone
  else's (`inference_grants`), so "how much did Sarah spend improving
  herself" is a query, not a shrug.

  The loop itself is the ordinary `OpenAgents.Work.JobServer`; this module only
  answers the kind-specific questions it asks.
  """

  require Logger

  alias OpenAgents.Inference
  alias OpenAgents.Repo
  alias OpenAgents.Roles
  alias OpenAgents.Roles.SelectionInput
  alias OpenAgents.Tools.Repository
  alias OpenAgents.Work.Job

  @kind "coding"

  @doc "Whether a job row is a coding job."
  def coding?(%Job{kind: @kind}), do: true
  def coding?(_job), do: false

  @doc """
  The additional tool authorities a coding job holds on top of the base job
  set — this is what surfaces the repository tool family to these jobs and
  ONLY these jobs (turns and other kinds never carry them).
  """
  def authorities, do: ["repository.read", "repository.write", "code.execute"]

  @doc """
  The role selection for a coding job: the admitted coding-lieutenant role,
  requested under host surface policy. Falls back to the default selection
  only if the role cannot be selected (it degrades, never blocks the job).
  """
  def role_selection do
    input = %SelectionInput{
      requested_role_id: "sarah.role.coding_lieutenant.v1",
      surface: "text",
      authority: "host_surface_policy",
      available_capabilities: authorities()
    }

    case Roles.select(input) do
      {:ok, selection} -> selection
      {:error, _reason} -> nil
    end
  end

  @doc "Approval receipts for the repository mutation modules (see Repository)."
  def approval_receipts(scope_ref, job_ref),
    do: Repository.approval_receipts(scope_ref, job_ref)

  @doc """
  Mint the job's inference grant at start; its id rides in the job's
  `delegation` map (the token is discarded — the meter is internal, nothing
  external redeems it).
  """
  def on_start(%Job{kind: @kind} = job) do
    case Inference.mint(%{
           owner_visitor_id: job.owner_visitor_id,
           conversation_id: job.conversation_id,
           machine_id: nil
         }) do
      {:ok, grant, _token} ->
        job
        |> Ecto.Changeset.change(%{
          delegation: Map.put(job.delegation || %{}, "inference_grant_id", grant.id)
        })
        |> Repo.update()

      {:error, reason} ->
        Logger.warning(
          "coding_job_grant_mint_failed code=#{OpenAgents.OperationalLog.code(reason)}"
        )

        {:ok, job}
    end
  end

  def on_start(job), do: {:ok, job}

  @doc """
  Terminal filesystem cleanup, called from `Work.finish_job/3` post-commit (the
  one path that runs even when the worker died). Grant settlement happens
  inside the same transaction as the terminal job row through
  `settle_grant/1`.
  """
  def on_terminal(%Job{kind: @kind} = job) do
    Repository.cleanup_workspace("work-job:#{job.id}")
    :ok
  end

  def on_terminal(_job), do: :ok

  @doc "Settle a coding job's metered grant inside the terminal job transaction."
  def settle_grant(%Job{kind: @kind, delegation: %{"inference_grant_id" => grant_id}} = job)
      when is_binary(grant_id) do
    case Repo.get(OpenAgents.Inference.Grant, grant_id) do
      nil ->
        {:error, :coding_grant_missing}

      grant ->
        usage = job.usage || %{}

        with {:ok, metered} <-
               Inference.record_usage(grant, %{
                 "input_tokens" => Map.get(usage, "input_tokens", 0),
                 "output_tokens" => Map.get(usage, "output_tokens", 0),
                 "total_tokens" => Map.get(usage, "total_tokens", 0)
               }),
             {:ok, settled} <- Inference.revoke(metered) do
          {:ok, settled}
        end
    end
  end

  def settle_grant(%Job{kind: @kind}), do: {:ok, :no_grant}
  def settle_grant(_job), do: {:ok, :not_coding}
end
