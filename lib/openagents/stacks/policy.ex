defmodule OpenAgents.Stacks.Policy do
  @moduledoc """
  Policy evaluation bases for pull requests (docs/stacked-prs.md section 11).

  Every evaluation carries two bases as first-class fields. The direct base
  is the pull request's own base branch and drives diff presentation, layer
  boundaries, and base display. The effective base is the stack trunk (or
  the direct base for an unstacked pull request) and drives every policy
  decision: protection rules, required approvals, CODEOWNERS, and merge
  configuration.

  Policy configuration resolves from the effective base tree, never from
  the direct parent branch tree, so an unmerged lower layer editing
  `CODEOWNERS` or a workflow cannot weaken the rules an upper layer is
  held to. Once the lower layer lands on the trunk, the effective base OID
  advances and later evaluations legitimately see the new configuration.
  """

  alias OpenAgents.Forge.Browse
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.StackEntry

  @codeowners_paths [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"]

  @doc """
  The policy evaluation context for one pull request.

  Returns `{:ok, evaluation}` where the evaluation carries the head OID,
  the direct base (ref and live OID), the effective base (ref and live
  OID), and the stack context (`nil` for an unstacked pull request). Both
  base OIDs resolve live, so the evaluation always reflects the current
  refs.
  """
  def evaluation(%Repository{} = repository, %PullRequest{} = pull_request) do
    case Stacks.active_entry_for_pull_request(pull_request) do
      nil -> unstacked_evaluation(repository, pull_request)
      %StackEntry{} = entry -> stacked_evaluation(repository, pull_request, entry)
    end
  end

  @doc """
  A configuration blob resolved from the evaluation's effective base tree.

  Reads `path` at the effective base OID — never at the direct parent
  branch — and returns `{:ok, %{content, truncated, binary, size}}` or
  `{:error, :not_found}`.
  """
  def configuration_blob(%Repository{} = repository, evaluation, path)
      when is_binary(path) do
    Browse.blob(repository, evaluation.effective_base.oid, path)
  end

  @doc """
  The CODEOWNERS content governing this evaluation.

  Searches `.github/CODEOWNERS`, `CODEOWNERS`, then `docs/CODEOWNERS` in
  the effective base tree and returns
  `{:ok, %{path, content, source_oid}}` or `{:error, :not_found}`.
  """
  def codeowners(%Repository{} = repository, evaluation) do
    Enum.find_value(@codeowners_paths, {:error, :not_found}, fn path ->
      case configuration_blob(repository, evaluation, path) do
        {:ok, blob} ->
          {:ok, %{path: path, content: blob.content, source_oid: evaluation.effective_base.oid}}

        _other ->
          nil
      end
    end)
  end

  defp unstacked_evaluation(repository, pull_request) do
    with {:ok, base_oid} <- resolve(repository, pull_request.base_ref) do
      base = %{ref: pull_request.base_ref, oid: base_oid}

      {:ok,
       %{
         pull_request_id: pull_request.id,
         head_oid: pull_request.head_sha,
         direct_base: base,
         effective_base: base,
         stack: nil
       }}
    end
  end

  defp stacked_evaluation(repository, pull_request, entry) do
    stack = Stacks.get_stack_for_entry!(entry)

    with {:ok, direct_oid} <- resolve(repository, pull_request.base_ref),
         {:ok, trunk_oid} <- resolve(repository, stack.trunk_ref) do
      {:ok,
       %{
         pull_request_id: pull_request.id,
         head_oid: pull_request.head_sha,
         direct_base: %{ref: pull_request.base_ref, oid: direct_oid},
         effective_base: %{ref: stack.trunk_ref, oid: trunk_oid},
         stack: %{
           id: stack.id,
           number: stack.number,
           position: entry.position,
           size: length(stack.entries),
           health: stack.health
         }
       }}
    end
  end

  defp resolve(repository, ref) do
    case Browse.resolve_commit(repository, ref) do
      {:ok, oid} -> {:ok, oid}
      _other -> {:error, {:missing_ref, ref}}
    end
  end
end
