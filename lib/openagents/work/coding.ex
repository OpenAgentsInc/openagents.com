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
        Logger.warning("coding job grant mint failed: #{inspect(reason)}")
        {:ok, job}
    end
  end

  def on_start(job), do: {:ok, job}

  @doc """
  Terminal cleanup, called from `Work.finish_job/3` post-commit (the one
  path that runs even when the worker died): remove the per-job clone and
  record the job's total usage against its grant in the inference ledger.
  """
  def on_terminal(%Job{kind: @kind} = job) do
    Repository.cleanup_workspace("work-job:#{job.id}")
    record_grant_usage(job)
    :ok
  end

  def on_terminal(_job), do: :ok

  defp record_grant_usage(%Job{delegation: %{"inference_grant_id" => grant_id}} = job)
       when is_binary(grant_id) do
    case Repo.get(OpenAgents.Inference.Grant, grant_id) do
      nil ->
        :ok

      grant ->
        usage = job.usage || %{}

        Inference.record_usage(grant, %{
          "input_tokens" => Map.get(usage, "input_tokens", 0),
          "output_tokens" => Map.get(usage, "output_tokens", 0),
          "total_tokens" => Map.get(usage, "total_tokens", 0)
        })

        Inference.revoke(grant)
        :ok
    end
  rescue
    error ->
      Logger.warning("coding job grant usage record failed: #{Exception.message(error)}")
      :ok
  end

  defp record_grant_usage(_job), do: :ok
end
