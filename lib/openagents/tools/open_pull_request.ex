defmodule OpenAgents.Tools.OpenPullRequest do
  @moduledoc "Opens an approved draft pull request from a Forge publication receipt."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Accounts.User
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories.RepositoryPublication
  alias OpenAgents.Repo
  alias OpenAgents.Tools.{ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.open_pull_request.v1",
      name: "open_pull_request",
      version: 1,
      description:
        "Open or refresh a draft pull request from an accepted repository publication receipt. " <>
          "The server loads and validates the receipt, repository policy, branch, commit, and Forge WAL authority.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "publication_receipt_ref" => %{
            "type" => "string",
            "pattern" => "^repository-publication:[0-9a-f-]{36}$"
          },
          "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 256},
          "body" => %{"type" => "string", "maxLength" => 65_536},
          "draft" => %{"type" => "boolean", "default" => true}
        },
        "required" => ["publication_receipt_ref", "title", "body"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :external_effect,
      required_scope: "browser_conversation",
      required_authority: "repository.write",
      executor: %{
        id: "openagents.forge.pull_requests",
        disclosure: "the OpenAgents pull request service, using an accepted Forge publication"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "host",
        "consent" => "approved_publication_pull_request"
      },
      module_metadata:
        Metadata.first_party("repository.write", "browser_conversation",
          effect: :external_effect,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text", "voice"],
          approval_class: "external_confirmation",
          approval_enforcement: "host_receipt"
        ),
      timeout_ms: 30_000,
      maximum_input_bytes: 72_000,
      maximum_output_bytes: 16_384,
      implementation: __MODULE__
    }
  end

  @doc "Builds the separate person approval required to open a pull request."
  def approval_receipt(scope_ref, approval_ref)
      when is_binary(scope_ref) and is_binary(approval_ref) do
    %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "external_confirmation",
      "module_id" => specification().module_id,
      "version" => specification().version,
      "scope_ref" => scope_ref,
      "explicit" => true,
      "actor_type" => "person",
      "receipt_ref" => approval_ref
    }
  end

  @impl true
  def execute(%{"publication_receipt_ref" => receipt_ref} = arguments, context) do
    with {:ok, publication_id} <- parse_receipt_ref(receipt_ref),
         %RepositoryPublication{} = publication <- Repo.get(RepositoryPublication, publication_id),
         :ok <- validate_context(publication, context),
         %User{} = actor <- Repo.get(User, context.owner_user_id),
         {:ok, pull_request} <- PullRequests.open_from_publication(publication, arguments, actor) do
      result = result(pull_request)

      {:ok,
       %ExecutionResult{
         result: result,
         target_receipt_refs: [
           receipt_ref,
           "pull-request:#{pull_request.id}",
           "issue:#{pull_request.repository_id}:#{pull_request.issue.number}"
         ]
       }}
    else
      nil -> {:error, :publication_receipt_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :publication_scope_mismatch}
    end
  end

  defp parse_receipt_ref("repository-publication:" <> publication_id) do
    case Ecto.UUID.cast(publication_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :publication_receipt_invalid}
    end
  end

  defp parse_receipt_ref(_receipt_ref), do: {:error, :publication_receipt_invalid}

  defp validate_context(publication, context) do
    workspace = context.workspace || %{}

    cond do
      publication.owner_user_id != context.owner_user_id ->
        {:error, :publication_scope_mismatch}

      publication.conversation_id != context.conversation_id ->
        {:error, :publication_scope_mismatch}

      workspace["repository_id"] != publication.repository_id ->
        {:error, :publication_workspace_mismatch}

      workspace["workspace_ref"] != publication.workspace_ref ->
        {:error, :publication_workspace_mismatch}

      true ->
        :ok
    end
  end

  defp result(pull_request) do
    %{
      "schema" => "openagents.pull_request_opened.v1",
      "id" => pull_request.id,
      "number" => pull_request.issue.number,
      "state" => pull_request.state,
      "draft" => pull_request.draft,
      "title" => pull_request.issue.title,
      "head" => %{"ref" => pull_request.head_ref, "oid" => pull_request.head_sha},
      "base" => %{"ref" => pull_request.base_ref, "oid" => pull_request.base_sha},
      "publication_receipt_ref" =>
        "repository-publication:#{pull_request.repository_publication_id}",
      "receipt" => %{
        "schema" => "openagents.pull_request_receipt.v1",
        "receipt_ref" => "pull-request:#{pull_request.id}"
      }
    }
  end
end
