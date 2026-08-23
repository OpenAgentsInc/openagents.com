defmodule OpenAgentsWeb.StackController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Repositories
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.Merge
  alias OpenAgents.Stacks.Restack
  alias OpenAgentsWeb.ControllerHelpers

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    render(conn, :index, stacks: Stacks.list(repository), owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "stack_number" => number}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    stack = Stacks.get_by_number!(repository, ControllerHelpers.integer_param!(number))
    render(conn, :show, stack: stack, owner: owner, repo: repo)
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, {stack, replay_state}} <-
           Stacks.create_from_api(repository, params, conn.assigns.current_user, idempotency_key) do
      conn
      |> put_status(:created)
      |> render(:show, stack: stack, owner: owner, repo: repo, replay_state: replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def append(conn, %{"owner" => owner, "repo" => repo, "stack_number" => number} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, {stack, replay_state}} <-
           Stacks.append_from_api(
             repository,
             ControllerHelpers.integer_param!(number),
             params,
             conn.assigns.current_user,
             idempotency_key
           ) do
      render(conn, :show, stack: stack, owner: owner, repo: repo, replay_state: replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def unstack(conn, %{"owner" => owner, "repo" => repo, "stack_number" => number} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, {stack, replay_state}} <-
           Stacks.unstack_from_api(
             repository,
             ControllerHelpers.integer_param!(number),
             params,
             conn.assigns.current_user,
             idempotency_key
           ) do
      render(conn, :show, stack: stack, owner: owner, repo: repo, replay_state: replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def dissolve(conn, %{"owner" => owner, "repo" => repo, "stack_number" => number} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, {stack, replay_state}} <-
           Stacks.dissolve_from_api(
             repository,
             ControllerHelpers.integer_param!(number),
             params,
             conn.assigns.current_user,
             idempotency_key
           ) do
      render(conn, :show, stack: stack, owner: owner, repo: repo, replay_state: replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def rebase(conn, %{"owner" => owner, "repo" => repo, "stack_number" => number} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, {operation, replay_state}} <-
           Restack.request_from_api(
             repository,
             ControllerHelpers.integer_param!(number),
             params,
             conn.assigns.current_user,
             idempotency_key
           ) do
      conn
      |> put_status(:accepted)
      |> render(:operation, operation: operation, replay_state: replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def merge(conn, %{"owner" => owner, "repo" => repo, "stack_number" => number} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, {operation, replay_state}} <-
           Merge.request_from_api(
             repository,
             ControllerHelpers.integer_param!(number),
             params,
             conn.assigns.current_user,
             idempotency_key
           ) do
      conn
      |> put_status(:accepted)
      |> render(:operation, operation: operation, replay_state: replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def merge_async(conn, %{"owner" => owner, "repo" => repo, "pull_number" => number} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)
    pull_number = ControllerHelpers.integer_param!(number)

    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, {operation, replay_state}} <-
           Merge.request_for_pull_request(
             repository,
             pull_number,
             params,
             conn.assigns.current_user,
             idempotency_key
           ) do
      conn
      |> put_status(:accepted)
      |> render(:merge_async,
        operation: operation,
        replay_state: replay_state,
        owner: owner,
        repo: repo,
        pull_number: pull_number
      )
    else
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def merge_async_status(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    pull_number = ControllerHelpers.integer_param!(params["pull_number"])

    case Merge.get_operation_for_pull_request(repository, pull_number, params["operation_id"]) do
      {:ok, operation} ->
        render(conn, :merge_async,
          operation: operation,
          replay_state: nil,
          owner: owner,
          repo: repo,
          pull_number: pull_number
        )

      {:error, reason} ->
        render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show_operation(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    case Restack.get_operation(
           repository,
           ControllerHelpers.integer_param!(params["stack_number"]),
           params["operation_id"]
         ) do
      {:ok, operation} -> render(conn, :operation, operation: operation, replay_state: nil)
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def continue_operation(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    case Restack.continue_from_api(
           repository,
           ControllerHelpers.integer_param!(params["stack_number"]),
           params["operation_id"],
           params,
           conn.assigns.current_user
         ) do
      {:ok, operation} -> render(conn, :operation, operation: operation, replay_state: nil)
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def abort_operation(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns.current_user)

    case Restack.abort_from_api(
           repository,
           ControllerHelpers.integer_param!(params["stack_number"]),
           params["operation_id"],
           conn.assigns.current_user
         ) do
      {:ok, operation} -> render(conn, :operation, operation: operation, replay_state: nil)
      {:error, reason} -> render_error(conn, reason)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) in 1..200 ->
        if String.contains?(key, ["\r", "\n", "\0"]),
          do: {:error, :invalid_idempotency_key},
          else: {:ok, key}

      _invalid ->
        {:error, :invalid_idempotency_key}
    end
  end

  defp render_error(conn, :invalid_idempotency_key),
    do: error(conn, :bad_request, "Provide one Idempotency-Key header")

  defp render_error(conn, :forbidden),
    do: error(conn, :forbidden, "You cannot modify stacks in this repository.")

  defp render_error(conn, reason)
       when reason in [:stack_not_found, :pull_request_not_found, :operation_not_found],
       do: not_found(conn)

  defp render_error(conn, {:operation_in_progress, operation_id}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      message: message(:operation_in_progress),
      code: "operation_in_progress",
      operation_id: operation_id
    })
  end

  defp render_error(conn, reason)
       when reason in [
              :idempotency_conflict,
              :stale_stack_version,
              :expected_head_mismatch,
              :stack_not_open,
              :operation_not_waiting,
              :operation_not_abortable,
              :merge_queue_unavailable
            ],
       do: conflict(conn, reason)

  defp render_error(conn, reason)
       when reason in [
              :invalid_request,
              :invalid_ref,
              :trunk_mismatch,
              :empty_stack,
              :repository_mismatch,
              :cross_repository_head,
              :pull_request_not_open,
              :duplicate_pull_request,
              :duplicate_branch,
              :broken_base_chain,
              :unrelated_history,
              :already_stacked,
              :not_stack_top,
              :not_stacked,
              :stack_too_large,
              :resolution_not_found,
              :resolution_parent_mismatch,
              :pull_request_not_in_stack
            ] do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{message: message(reason), code: Atom.to_string(reason)})
  end

  defp conflict(conn, reason) do
    conn
    |> put_status(:conflict)
    |> json(%{message: message(reason), code: Atom.to_string(reason)})
  end

  defp message(:idempotency_conflict), do: "The idempotency key is already in use."
  defp message(:stale_stack_version), do: "The stack version does not match."
  defp message(:expected_head_mismatch), do: "An expected head OID does not match."
  defp message(:stack_not_open), do: "The stack is not open."
  defp message(:invalid_request), do: "The request body is invalid."
  defp message(:invalid_ref), do: "A ref did not resolve to a commit."
  defp message(:trunk_mismatch), do: "The bottom pull request does not target the trunk ref."
  defp message(:empty_stack), do: "A stack needs at least one pull request."
  defp message(:repository_mismatch), do: "Every pull request must belong to this repository."
  defp message(:cross_repository_head), do: "Every head branch must live in this repository."
  defp message(:pull_request_not_open), do: "Every pull request must be open."
  defp message(:duplicate_pull_request), do: "A pull request appears more than once."
  defp message(:duplicate_branch), do: "A branch appears more than once."
  defp message(:broken_base_chain), do: "The direct-base chain is broken."
  defp message(:unrelated_history), do: "A branch shares no history with its parent."
  defp message(:already_stacked), do: "A pull request already belongs to an active stack."
  defp message(:not_stack_top), do: "The pull request does not target the current top head."
  defp message(:operation_in_progress), do: "Another operation is active on this stack."
  defp message(:operation_not_waiting), do: "The operation is not waiting for a resolution."
  defp message(:operation_not_abortable), do: "The operation can no longer be aborted."
  defp message(:resolution_not_found), do: "The resolution commit does not exist."

  defp message(:merge_queue_unavailable),
    do: "The merge queue is not available; use a direct merge."

  defp message(:pull_request_not_in_stack),
    do: "The pull request is not an active entry of this stack."

  defp message(:not_stacked),
    do: "The pull request does not belong to an active stack."

  defp message(:stack_too_large),
    do: "A stack holds at most #{Stacks.max_entries()} pull requests."

  defp message(:resolution_parent_mismatch),
    do: "The resolution commit does not build on the persisted parent."

  defp not_found(conn), do: error(conn, :not_found, "Not Found")
  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{message: message})
end
