defmodule OpenAgents.Tools.RepoCommitPush do
  @moduledoc """
  Commits this job's clone and pushes to the job's own `sarah/job-<id>`
  branch on Sarah's own forge — never GitHub, never another ref
  (SELF-EDIT-001). The commit SHA lands in the tool outcome receipt; the
  forge's WAL entry for the push is the durable artifact digest.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Repository, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.repo_commit_push.v1",
      name: "repo_commit_push",
      version: 1,
      description:
        "Commits all changes in this coding job's clone and pushes them to this job's own " <>
          "branch on Sarah's forge. Pass message as the commit message. The push branch is " <>
          "fixed to this job; any other branch is refused. Returns the commit sha.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string", "maxLength" => 2_000},
          "branch" => %{"type" => "string", "maxLength" => 200}
        },
        "required" => ["message"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :external_effect,
      required_scope: "browser_conversation",
      required_authority: "repository.write",
      executor: %{
        id: "sarah.repository.self",
        disclosure: "Sarah's own runtime, pushing this job's branch to her own forge"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "host",
        "consent" => "job_goal"
      },
      module_metadata:
        Metadata.first_party("repository.write", "browser_conversation",
          effect: :external_effect,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text"],
          approval_class: "explicit_operator_approval",
          approval_enforcement: "host_receipt"
        ),
      timeout_ms: 60_000,
      maximum_input_bytes: 8_192,
      maximum_output_bytes: 16_384,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"message" => message} = arguments, %{job_ref: job_ref} = context)
      when is_binary(message) and is_binary(job_ref) do
    branch = Repository.job_branch(job_ref)

    with :ok <- validate_branch(Map.get(arguments, "branch"), branch),
         {:ok, workspace} <- Repository.tool_root("workspace", context),
         {:ok, sha} <- commit(workspace, message),
         :ok <- push(workspace, branch) do
      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.repo_commit_push_result.v1",
           "sha" => sha,
           "branch" => branch,
           "repo" => Repository.repo()
         },
         target_receipt_refs: [
           "forge-commit:#{Repository.repo()}:#{sha}",
           "forge-branch:#{Repository.repo()}:#{branch}"
         ]
       }}
    end
  end

  def execute(_arguments, _context), do: {:error, :repository_workspace_unavailable}

  # The job's branch is not a choice — passing anything else is refused.
  defp validate_branch(nil, _job_branch), do: :ok
  defp validate_branch(branch, branch), do: :ok
  defp validate_branch(_other, _job_branch), do: {:error, :branch_refused}

  defp commit(workspace, message) do
    {_, 0} = Repository.git(workspace, ["add", "-A"])

    case Repository.git(workspace, [
           "-c",
           "user.name=Sarah",
           "-c",
           "user.email=sarah@openagents.com",
           "commit",
           "-m",
           message
         ]) do
      {_, 0} ->
        {sha, 0} = Repository.git(workspace, ["rev-parse", "HEAD"])
        {:ok, String.trim(sha)}

      {output, _} ->
        if output =~ "nothing to commit" do
          {:error, :nothing_to_commit}
        else
          {:error, :commit_failed}
        end
    end
  end

  defp push(workspace, branch) do
    case Repository.push_url() do
      url when is_binary(url) and url != "" ->
        case Repository.git(workspace, [
               "-c",
               "credential.helper=",
               "push",
               url,
               "HEAD:refs/heads/#{branch}"
             ]) do
          {_, 0} -> :ok
          {_output, _} -> {:error, :push_failed}
        end

      _unset ->
        {:error, :forge_push_unconfigured}
    end
  end
end
