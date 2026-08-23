defmodule OpenAgents.Tools.Runner do
  @moduledoc "Validates and executes calls only against one captured tool catalog snapshot."

  alias OpenAgents.Modules.SurfacePolicy
  alias OpenAgents.Observability
  alias OpenAgents.Tools.{ExecutionContext, ExecutionResult, Registry, Schema, Snapshot, Tool}

  @schema "sarah.tool_outcome.v1"
  @maximum_reference_count 64

  @type call :: %{
          required(:call_id) => String.t(),
          required(:name) => String.t(),
          required(:version) => pos_integer(),
          required(:raw_arguments) => String.t()
        }

  @spec run(Snapshot.t(), call(), ExecutionContext.t(), keyword()) ::
          {:ok, map()} | {:error, :invalid_call_id}
  def run(%Snapshot{} = snapshot, call, %ExecutionContext{} = context, options \\ [])
      when is_map(call) do
    started_at = DateTime.utc_now()

    if valid_reference?(call[:call_id]) do
      result = execute(snapshot, call, context, options, started_at)
      result = attach_workspace(result, context.workspace)
      {:ok, outcome} = result
      duration_ms = max(DateTime.diff(DateTime.utc_now(), started_at, :millisecond), 0)
      _telemetry_result = Observability.tool_outcome(outcome, context.surface, duration_ms)
      result
    else
      {:error, :invalid_call_id}
    end
  end

  defp attach_workspace({:ok, outcome}, workspace) when is_map(workspace),
    do: {:ok, Map.put(outcome, "workspace", workspace)}

  defp attach_workspace(result, _workspace), do: result

  defp execute(snapshot, call, context, options, started_at) do
    case Registry.fetch(snapshot, call[:name], call[:version]) do
      {:ok, tool} -> execute_known(snapshot, tool, call, context, options, started_at)
      {:error, reason} -> {:ok, failure_outcome(call, nil, reason, started_at)}
    end
  end

  defp execute_known(snapshot, tool, call, context, options, started_at) do
    with {:ok, artifact} <- Registry.module_for_tool(snapshot, tool.name, tool.version),
         :ok <- validate_effect(tool),
         :ok <- SurfacePolicy.authorize_execution(artifact, context),
         :ok <- validate_scope(tool, context),
         :ok <- validate_not_cancelled(options),
         {:ok, arguments} <- decode_arguments(call[:raw_arguments], tool),
         :ok <- Schema.validate_value(arguments, tool.input_schema) do
      execute_admitted(tool, artifact, call[:call_id], arguments, context, options, started_at)
    else
      {:error, reason} -> {:ok, failure_outcome(call, tool, reason, started_at)}
    end
  end

  defp execute_admitted(tool, artifact, call_id, arguments, context, options, started_at) do
    context = %{context | current_tool_call_id: call_id}

    task =
      Task.Supervisor.async_nolink(OpenAgents.ToolTaskSupervisor, fn ->
        tool.implementation.execute(arguments, context)
      end)

    cancel? = Keyword.get(options, :cancel?, fn -> false end)

    timeout_ms = bounded_timeout(tool.timeout_ms, Keyword.get(options, :timeout_ms))

    case await(task, cancel?, timeout_ms) do
      {:ok, {:ok, %ExecutionResult{} = execution_result}} ->
        normalize_success(tool, artifact, call_id, execution_result, started_at)

      {:ok, {:error, reason}} when is_atom(reason) ->
        {:ok, failure_outcome(call_map(call_id, tool), tool, reason, started_at)}

      {:ok, _invalid_result} ->
        {:ok, failure_outcome(call_map(call_id, tool), tool, :invalid_tool_result, started_at)}

      {:exit, _reason} ->
        {:ok, failure_outcome(call_map(call_id, tool), tool, :tool_crashed, started_at)}

      :timeout ->
        _shutdown_result = Task.shutdown(task, :brutal_kill)
        {:ok, failure_outcome(call_map(call_id, tool), tool, :timeout, started_at)}

      :cancelled ->
        _shutdown_result = Task.shutdown(task, :brutal_kill)
        {:ok, failure_outcome(call_map(call_id, tool), tool, :cancelled, started_at)}
    end
  end

  defp bounded_timeout(tool_timeout_ms, nil), do: tool_timeout_ms

  defp bounded_timeout(tool_timeout_ms, host_timeout_ms)
       when is_integer(host_timeout_ms) and host_timeout_ms > 0,
       do: min(tool_timeout_ms, host_timeout_ms)

  defp bounded_timeout(tool_timeout_ms, _invalid_host_timeout), do: tool_timeout_ms

  defp normalize_success(tool, artifact, call_id, execution_result, started_at) do
    with :ok <- validate_result_status(execution_result.status),
         :ok <- Schema.validate_value(execution_result.result, tool.output_schema),
         {:ok, encoded} <- Jason.encode(execution_result.result),
         true <- byte_size(encoded) <= tool.maximum_output_bytes,
         :ok <- validate_refs(execution_result.target_receipt_refs),
         :ok <- validate_refs(execution_result.attribution_refs),
         :ok <- validate_effect_receipt(artifact, execution_result.target_receipt_refs) do
      {:ok,
       base_outcome(call_id, tool, execution_result.status, started_at)
       |> Map.put("result", execution_result.result)
       |> Map.put("error", bounded_result_error(execution_result))
       |> Map.put("target_receipt_refs", execution_result.target_receipt_refs)
       |> Map.put(
         "attribution_refs",
         Enum.uniq(tool.attribution ++ execution_result.attribution_refs)
       )}
    else
      false ->
        {:ok, failure_outcome(call_map(call_id, tool), tool, :output_too_large, started_at)}

      {:error, reason} ->
        {:ok,
         failure_outcome(
           call_map(call_id, tool),
           tool,
           normalize_output_error(reason),
           started_at
         )}
    end
  end

  defp decode_arguments(raw_arguments, tool)
       when is_binary(raw_arguments) and byte_size(raw_arguments) <= tool.maximum_input_bytes do
    case Jason.decode(raw_arguments) do
      {:ok, arguments} when is_map(arguments) -> {:ok, arguments}
      {:ok, _not_object} -> {:error, :arguments_must_be_an_object}
      {:error, _decode_error} -> {:error, :invalid_arguments_json}
    end
  end

  defp decode_arguments(_raw_arguments, _tool), do: {:error, :arguments_too_large}

  defp validate_effect(%Tool{side_effect: :read_only}), do: :ok
  defp validate_effect(%Tool{side_effect: :reversible_write}), do: :ok
  defp validate_effect(%Tool{side_effect: :external_effect}), do: :ok

  defp validate_effect_receipt(artifact, refs) do
    if SurfacePolicy.require_target_receipt?(artifact) and refs == [],
      do: {:error, :target_receipt_required},
      else: :ok
  end

  defp validate_scope(tool, context) do
    cond do
      tool.required_scope != context.scope ->
        {:error, :scope_refused}

      not MapSet.member?(context.authorities, tool.required_authority) ->
        {:error, :authority_refused}

      not valid_reference?(context.scope_ref) ->
        {:error, :scope_refused}

      true ->
        :ok
    end
  end

  defp validate_not_cancelled(options) do
    cancel? = Keyword.get(options, :cancel?, fn -> false end)

    cond do
      not is_function(cancel?, 0) -> {:error, :invalid_cancellation_check}
      cancel?.() -> {:error, :cancelled}
      true -> :ok
    end
  end

  defp await(task, cancel?, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_until(task, cancel?, deadline)
  end

  defp await_until(task, cancel?, deadline) do
    cond do
      cancel?.() ->
        :cancelled

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        remaining = deadline - System.monotonic_time(:millisecond)

        case Task.yield(task, min(remaining, 10)) do
          nil -> await_until(task, cancel?, deadline)
          result -> result
        end
    end
  end

  defp base_outcome(call_id, tool, status, started_at) do
    %{
      "schema" => @schema,
      "call_id" => call_id,
      "module_ref" => %{
        "module_id" => tool.module_id,
        "tool_name" => tool.name,
        "version" => tool.version,
        "artifact_digest" => Map.get(tool.executor, :module_artifact_digest)
      },
      "executor_ref" => %{
        "id" => tool.executor.id,
        "disclosure" => tool.executor.disclosure,
        "implementation_digest" => Map.get(tool.executor, :implementation_digest)
      },
      "status" => status,
      "result" => nil,
      "error" => nil,
      "target_receipt_refs" => [],
      "attribution_refs" => tool.attribution,
      "started_at" => DateTime.to_iso8601(started_at),
      "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp failure_outcome(call, tool, reason, started_at) do
    status = failure_status(reason)
    tool = tool || unavailable_tool(call)

    base_outcome(call[:call_id], tool, status, started_at)
    |> Map.put("error", %{"code" => error_code(reason), "message" => error_message(reason)})
  end

  defp unavailable_tool(call) do
    %Tool{
      module_id: "sarah.host",
      name: safe_name(call[:name]),
      version: safe_version(call[:version]),
      description: "Unavailable tool request",
      input_schema: %{"type" => "object", "properties" => %{}},
      output_schema: %{"type" => "object", "properties" => %{}},
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "none",
      executor: %{id: "sarah.host", disclosure: "Sarah host policy"},
      maintainer: "OpenAgents",
      attribution: [],
      policy_facets: %{},
      module_metadata: %{},
      timeout_ms: 1,
      maximum_input_bytes: 1,
      maximum_output_bytes: 1,
      implementation: __MODULE__
    }
  end

  defp validate_result_status(status) do
    if status in OpenAgents.Tools.ExecutionResult.statuses(),
      do: :ok,
      else: {:error, :invalid_tool_result}
  end

  # A tool-reported non-succeeded outcome carries a bounded typed error; a
  # succeeded outcome never carries one, whatever the tool set.
  defp bounded_result_error(%{status: "succeeded"}), do: nil

  defp bounded_result_error(%{status: status, error: error}) do
    code =
      case error do
        %{"code" => code} when is_binary(code) and byte_size(code) <= 64 -> code
        _missing -> status
      end

    message =
      case error do
        %{"message" => message} when is_binary(message) ->
          String.slice(message, 0, 500)

        _missing ->
          "The brokered work ended #{status}."
      end

    %{"code" => code, "message" => message}
  end

  defp failure_status(:cancelled), do: "cancelled"

  defp failure_status(reason)
       when reason in [
              :scope_refused,
              :authority_refused,
              :unsupported_side_effect,
              :surface_not_admitted,
              :surface_unknown,
              :module_approval_required,
              :memory_consent_required,
              :memory_consent_mismatch,
              :memory_policy_refused,
              :publication_scope_mismatch,
              :publication_workspace_mismatch,
              :publication_not_accepted,
              :publication_receipt_invalid,
              :publication_receipt_stale,
              :publication_branch_refused,
              :pull_requests_disabled,
              :forbidden
            ],
       do: "refused"

  defp failure_status(reason)
       when reason in [
              :unknown_tool,
              :incompatible_tool_version,
              :module_artifact_missing,
              :module_executor_unavailable,
              :module_integrity_mismatch
            ],
       do: "unavailable"

  defp failure_status(_reason), do: "failed"

  defp error_code(reason) when is_atom(reason) do
    code = Atom.to_string(reason)
    if byte_size(code) <= 64, do: code, else: "tool_failure"
  end

  defp error_code(_reason), do: "tool_failure"

  defp error_message(:unknown_tool), do: "That tool is not in this turn's catalog."

  defp error_message(:incompatible_tool_version),
    do: "That tool version is not in this turn's catalog."

  defp error_message(:module_integrity_mismatch),
    do: "The module executor no longer matches this turn's immutable artifact."

  defp error_message(:module_executor_unavailable),
    do: "The captured module executor is unavailable."

  defp error_message(:module_artifact_missing),
    do: "The tool has no matching module artifact in this turn's registry."

  defp error_message(:scope_refused), do: "The tool is not authorized for this data scope."
  defp error_message(:authority_refused), do: "The required authority is not present."
  defp error_message(:surface_not_admitted), do: "That module is not admitted on this surface."
  defp error_message(:surface_unknown), do: "That execution surface is not recognized."

  defp error_message(:module_approval_required),
    do: "That effect requires an exact current approval receipt."

  defp error_message(:target_receipt_required),
    do: "The executor did not return evidence of the affected target."

  defp error_message(:unsupported_side_effect),
    do: "This release does not execute that side-effect class."

  defp error_message(:timeout), do: "The tool exceeded its time limit."
  defp error_message(:cancelled), do: "The tool call was cancelled."
  defp error_message(:not_found), do: "No source exists in this conversation snapshot."
  defp error_message(:invalid_source_ref), do: "The source reference is invalid."
  defp error_message(:invalid_time_bound), do: "The requested time bound is invalid."
  defp error_message(:invalid_result_limit), do: "The requested result limit is invalid."
  defp error_message(:invalid_context_limit), do: "The requested context limit is invalid."
  defp error_message(:lexical_unavailable), do: "Conversation recall is temporarily unavailable."

  defp error_message(:memory_consent_required),
    do: "The current user action did not explicitly authorize that memory change."

  defp error_message(:memory_consent_mismatch),
    do: "The requested memory change does not exactly match the authorized candidate."

  defp error_message(:memory_policy_refused),
    do: "The memory policy refused that candidate without retaining it."

  defp error_message(:output_too_large), do: "The tool output exceeded its size limit."

  defp error_message(:repository_workspace_unavailable),
    do: "Repository mutation is only available inside a coding job's own workspace."

  defp error_message(:workspace_required),
    do: "This tool requires an explicit repository or computer workspace."

  defp error_message(:canonical_workspace_refused),
    do: "This tool cannot operate on a canonical repository or application checkout."

  defp error_message(:workspace_read_only), do: "The assigned workspace is read-only."
  defp error_message(:invalid_workspace_path), do: "The workspace path is invalid."
  defp error_message(:reserved_workspace_path), do: "That workspace path is host-reserved."
  defp error_message(:workspace_path_escape), do: "The path escapes the assigned workspace."
  defp error_message(:workspace_symlink_refused), do: "The path crosses a symbolic link."
  defp error_message(:workspace_file_not_found), do: "The workspace file does not exist."
  defp error_message(:workspace_path_is_directory), do: "The requested path is a directory."
  defp error_message(:workspace_path_not_regular), do: "The requested path is not a regular file."
  defp error_message(:workspace_invalid_encoding), do: "The file is not valid UTF-8 text."
  defp error_message(:invalid_read_range), do: "The requested line range is invalid."

  defp error_message(:workspace_line_too_large),
    do: "A single line exceeds the 50 KiB read limit."

  defp error_message(:workspace_snapshot_root_invalid),
    do: "The host snapshot store must be outside the assigned workspace."

  defp error_message(:invalid_edits), do: "The edit batch is invalid."
  defp error_message(:overlapping_edits), do: "The edit batch contains overlapping matches."

  defp error_message(:stale_workspace_digest),
    do: "The file changed after it was read. Read it again before editing."

  defp error_message(:invalid_repository_path),
    do: "The path is outside the repository or invalid."

  defp error_message(:repository_file_not_found), do: "No such file in that repository tree."

  defp error_message(:repository_authentication_required),
    do: "Sign in to read a connected repository."

  defp error_message(:repository_not_found),
    do: "The repository does not exist or you cannot access it."

  defp error_message(:ambiguous_repository_name),
    do: "More than one visible repository has that name. Use owner/name."

  defp error_message(:invalid_repository),
    do: "The repository must be an owner/name path or an unambiguous repository name."

  defp error_message(:invalid_repository_ref), do: "The repository ref is invalid."
  defp error_message(:repository_readme_not_found), do: "The repository has no readable README."

  defp error_message(:repository_ref_or_file_not_found),
    do: "The requested file or ref does not exist."

  defp error_message(:repository_ref_or_directory_not_found),
    do: "The requested directory or ref does not exist."

  defp error_message(:repository_binary_file),
    do: "The requested repository file is binary and cannot be read as text."

  defp error_message(:invalid_search_pattern), do: "The search pattern is not a valid regex."
  defp error_message(:invalid_code_content), do: "The code content is missing or invalid."
  defp error_message(:empty_match_string), do: "The text to replace must not be empty."
  defp error_message(:edit_is_noop), do: "The replacement must change the matched text."

  defp error_message(:no_match),
    do: "The text to replace was not found. Read the file again before editing it."

  defp error_message(:ambiguous_match),
    do: "The text to replace matches more than once. Include more surrounding context."

  defp error_message(:branch_refused),
    do: "A coding job may push only to its own openagents/job-<id> branch."

  defp error_message(:nothing_to_commit), do: "The workspace has no changes to commit."
  defp error_message(:commit_failed), do: "git commit failed in the job workspace."
  defp error_message(:push_failed), do: "The push to the forge was rejected or failed."

  defp error_message(:forge_push_unconfigured),
    do: "This deployment has no forge push endpoint configured."

  defp error_message(:publication_receipt_invalid),
    do: "The repository publication receipt is invalid."

  defp error_message(:publication_receipt_not_found),
    do: "The repository publication receipt does not exist."

  defp error_message(:publication_scope_mismatch),
    do: "The repository publication does not belong to this account and conversation."

  defp error_message(:publication_workspace_mismatch),
    do: "The repository publication does not belong to this conversation workspace."

  defp error_message(:publication_not_accepted),
    do: "The repository publication has not been accepted by Forge."

  defp error_message(:publication_receipt_stale),
    do: "The published branch no longer matches the exact Forge publication receipt."

  defp error_message(:publication_branch_refused),
    do: "A pull request must use an OpenAgents chat publication branch."

  defp error_message(:forge_authority_unavailable),
    do: "Forge could not verify the authoritative branch state."

  defp error_message(:pull_requests_disabled),
    do: "Pull requests are disabled for this repository."

  defp error_message(:forbidden),
    do: "Your account cannot open a pull request in this repository."

  defp error_message({:workspace_clone_failed, _detail}),
    do: "Cloning the job workspace from the forge failed."

  defp error_message(_reason), do: "The tool call failed validation or execution."

  defp validate_refs(refs) when is_list(refs) and length(refs) <= @maximum_reference_count do
    if Enum.all?(refs, &valid_reference?/1), do: :ok, else: {:error, :invalid_result_references}
  end

  defp validate_refs(_refs), do: {:error, :invalid_result_references}

  defp valid_reference?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= 256

  defp normalize_output_error(reason)
       when reason in [
              :type_mismatch,
              :required_property_missing,
              :additional_property_not_allowed,
              :array_too_large,
              :string_too_long
            ],
       do: :invalid_tool_output

  defp normalize_output_error(reason), do: reason

  defp call_map(call_id, tool), do: %{call_id: call_id, name: tool.name, version: tool.version}
  defp safe_name(name) when is_binary(name) and byte_size(name) <= 128, do: name
  defp safe_name(_name), do: "unknown"
  defp safe_version(version) when is_integer(version) and version > 0, do: version
  defp safe_version(_version), do: 1
end
