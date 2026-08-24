defmodule OpenAgents.Tools.IssueCapture do
  @moduledoc """
  Files one unmet request from a conversation as a scoped forge issue.

  The behavior lives in `OpenAgents.Issues.Capture`, which
  `POST /api/v3/repos/:owner/:repo/issues/capture` also calls, so the tool and
  the API operation cannot drift apart.

  ## Why this one is `:external_effect`

  A filed issue is public, has a number other people cite, and notifies
  everyone watching the repository. Nothing on disk changed, which is exactly
  why the honest classification is easy to get wrong; the coder specification
  settles it directly — "'open an issue' is an external effect even though
  nothing on your disk changed" (`docs/2026-08-23-openagents-coder-cli-spec.md`,
  section 7.2). Its ladder puts tracker writes at **ask every time**, so this
  tool declares `approval_class: "external_confirmation"` — the class
  `OpenAgents.Modules.SurfacePolicy` requires of an external effect, and the
  one `open_pull_request` already uses for the same reason — with
  `approval_enforcement: "host_receipt"`.

  `OpenAgents.Modules.SurfacePolicy.approval/2` then demands a current,
  explicit, person-signed receipt bound to this exact module, version, and
  conversation before the tool runs — and `OpenAgents.Tools.AdmittedCatalog`
  applies the same check when it builds the catalog, so on a turn where the
  person has not consented the tool is not offered rather than offered and
  refused. There is no standing grant and no "always" to record: the receipt is
  scoped to one conversation and checked again on every call.

  ## Authority is the caller's

  The requesting account's own membership decides where an issue can be filed.
  `Capture.authorize/2` reads `OpenAgents.Repositories.writable?/2` for that
  account and nothing else, so the agent cannot file somewhere the person could
  not have filed by hand, and a caller without a writing role gets
  `repository_write_access_required` naming what is missing. The repository is
  always an argument, never a default: a request that names no repository is
  refused rather than routed to a guess.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues.Capture
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Repo
  alias OpenAgents.Tools.{ExecutionContext, ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.issue_capture.v1",
      name: "capture_issue",
      version: 1,
      description:
        "File the person's feature request or bug report as an issue in a Forge repository " <>
          "they can write to, drafted as outcome, current behavior, and acceptance criteria. " <>
          "Returns the issue number and URL, and returns the existing issue instead of a " <>
          "second one when an open issue already has the same title. " <>
          "Do not call this to answer a question, to look something up, or to record a " <>
          "preference or a note — filing a public issue is not a way to remember something. " <>
          "Do not call it without the person asking for the request to be tracked, and do not " <>
          "call it a second time for a request you already filed in this conversation. " <>
          "Do not guess the repository: ask which one if the person has not named it.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :external_effect,
      required_scope: "browser_conversation",
      required_authority: "repository.write",
      executor: %{
        id: "sarah.forge.issues",
        disclosure: "OpenAgents Forge, filing as the signed-in person"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "application_process",
        "consent" => "external_confirmation"
      },
      module_metadata:
        Metadata.first_party("repository.write", "browser_conversation",
          effect: :external_effect,
          privacy: "signed_browser_owner",
          residency: "application_process",
          approval_class: "external_confirmation",
          approval_enforcement: "host_receipt"
        ),
      timeout_ms: 15_000,
      maximum_input_bytes: 16_384,
      maximum_output_bytes: 8_192,
      implementation: __MODULE__,
      tags: ["forge", "issue", "tracker", "request", "file"],
      # Filing runs under the person's own membership, so an unresolved owner
      # can never succeed. The repository itself carries no reach requirement:
      # its gate is per-repository write membership, which depends on an
      # argument the catalog has not seen (TOOL-005).
      reach: [:signed_in_owner]
    }
  end

  @impl true
  def execute(%{"repository" => repository} = arguments, %ExecutionContext{} = context)
      when is_binary(repository) do
    with {:ok, actor} <- actor(context),
         {:ok, captured} <- Capture.capture(actor, repository, arguments) do
      {:ok,
       %ExecutionResult{
         result: result(captured),
         target_receipt_refs: ["forge-issue:#{captured.issue.id}"]
       }}
    else
      {:error, {:invalid_issue, _errors}} -> {:error, :invalid_issue}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_repository}

  defp actor(%ExecutionContext{owner_user_id: user_id}) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      %User{status: "active"} = user -> {:ok, user}
      _absent -> {:error, :repository_authentication_required}
    end
  end

  defp actor(%ExecutionContext{}), do: {:error, :repository_authentication_required}

  defp result(%{issue: issue, repository: repository, outcome: outcome}) do
    path = repository.owner <> "/" <> repository.name

    %{
      "schema" => "openagents.captured_issue.v1",
      "repository" => path,
      "number" => issue.number,
      "title" => issue.title,
      "state" => issue.state,
      "url" => url(path, issue.number),
      "outcome" => Atom.to_string(outcome)
    }
  end

  defp url(path, number) do
    String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/") <> "/#{path}/issues/#{number}"
  end

  defp input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["repository", "problem"],
      "properties" => %{
        "repository" => %{
          "type" => "string",
          "description" =>
            "The repository to file in, as owner/name. Required, and never guessed: " <>
              "ask the person which repository if they have not said."
        },
        "problem" => %{
          "type" => "string",
          "description" =>
            "The outcome the person wants, in their own words. Do not add anything they " <>
              "did not say, and do not include conversation, prompt, or credential text."
        },
        "current_behavior" => %{
          "type" => "string",
          "description" =>
            "What happens today, if the person described it. Leave this out rather than " <>
              "inventing behavior nobody observed."
        },
        "acceptance_criteria" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "What must be true for the request to be done, if the person said. " <>
              "Leave this out rather than inventing criteria."
        }
      }
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "required" => ["schema", "repository", "number", "url", "outcome"],
      "properties" => %{
        "schema" => %{"type" => "string"},
        "repository" => %{"type" => "string"},
        "number" => %{"type" => "integer"},
        "title" => %{"type" => "string"},
        "state" => %{"type" => "string"},
        "url" => %{"type" => "string"},
        "outcome" => %{
          "type" => "string",
          "enum" => ["created", "existing"],
          "description" =>
            "`created` for a new issue, `existing` when an open issue already matched."
        }
      }
    }
  end
end
