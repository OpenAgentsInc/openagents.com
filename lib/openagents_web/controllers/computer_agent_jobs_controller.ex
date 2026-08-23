defmodule OpenAgentsWeb.ComputerAgentJobsController do
  @moduledoc "Owner-authenticated API for durable coding-agent delegations."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Analytics
  alias OpenAgents.ComputerAgentJobs
  alias OpenAgents.Conversations
  alias OpenAgents.Machines
  alias OpenAgents.Work
  alias OpenAgents.Work.Job

  def create(conn, %{"computer_id" => computer_id} = params) do
    user = conn.assigns.current_user

    with {:ok, machine} <- Machines.get_machine(user.id, computer_id),
         {:ok, conversation} <- Conversations.ensure_conversation(user),
         {:ok, job} <- ComputerAgentJobs.start(user, machine, conversation, params) do
      Analytics.capture("agent_job_created", Analytics.distinct_id(user), %{
        "machine_tier" => machine.tier
      })

      conn
      |> put_status(:accepted)
      |> json(%{"job" => job_projection(job)})
    else
      {:error, reason} -> start_error(conn, reason)
    end
  end

  def show(conn, %{"id" => job_id}) do
    with {:ok, job} <- owned_job(conn.assigns.current_user.id, job_id) do
      json(conn, %{"job" => job_projection(job)})
    else
      {:error, :job_not_found} -> error(conn, :not_found, "job_not_found")
    end
  end

  def delete(conn, %{"id" => job_id}) do
    with {:ok, job} <- owned_job(conn.assigns.current_user.id, job_id),
         {:ok, result} <- Work.cancel_job(job.id) do
      status = if result == :stopping, do: "stopping", else: result.status
      conn |> put_status(:accepted) |> json(%{"job_id" => job.id, "status" => status})
    else
      {:error, :job_not_found} -> error(conn, :not_found, "job_not_found")
      {:error, _reason} -> error(conn, :conflict, "job_not_cancellable")
    end
  end

  defp owned_job(user_id, job_id) when is_binary(job_id) do
    with {:ok, _cast} <- Ecto.UUID.cast(job_id),
         %Job{kind: "delegation"} = job <- Work.get_job(job_id),
         %{user_id: ^user_id} <- Work.get_job_owner!(job) do
      {:ok, job}
    else
      _missing_or_foreign -> {:error, :job_not_found}
    end
  end

  defp owned_job(_user_id, _job_id), do: {:error, :job_not_found}

  defp start_error(conn, :computer_controller_disabled),
    do: error(conn, :not_found, "computer_controller_disabled")

  defp start_error(conn, :machine_not_found),
    do: error(conn, :not_found, "computer_not_found")

  defp start_error(conn, :machine_revoked),
    do: error(conn, :conflict, "computer_revoked")

  defp start_error(conn, :machine_offline),
    do: error(conn, :conflict, "computer_offline")

  defp start_error(conn, :agent_not_available),
    do: error(conn, :unprocessable_entity, "agent_not_available")

  defp start_error(conn, :cwd_not_allowed),
    do: error(conn, :unprocessable_entity, "cwd_not_allowed")

  defp start_error(conn, :invalid_delegation_request),
    do: error(conn, :unprocessable_entity, "invalid_delegation_request")

  defp start_error(conn, _reason), do: error(conn, :unprocessable_entity, "job_start_failed")

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{"error" => code})

  defp job_projection(%Job{} = job) do
    delegation = job.delegation || %{}

    %{
      "id" => job.id,
      "kind" => job.kind,
      "status" => job.status,
      "machine_id" => delegation["machine_id"],
      "machine_name" => delegation["machine_name"],
      "agent_id" => delegation["agent_id"],
      "cwd" => delegation["cwd"],
      "resume_session_id" => bounded(delegation["resume_session_id"], 128),
      "report" => bounded(job.report, 8_000),
      "error_code" => bounded(job.error_code, 128),
      "report_message_id" => job.report_message_id,
      "inserted_at" => iso8601(job.inserted_at),
      "started_at" => iso8601(job.started_at),
      "completed_at" => iso8601(job.completed_at)
    }
  end

  defp bounded(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded(_value, _maximum), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
