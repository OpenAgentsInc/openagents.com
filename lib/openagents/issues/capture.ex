defmodule OpenAgents.Issues.Capture do
  @moduledoc """
  Turns one sentence of a conversation into a scoped forge issue.

  This module is the whole of the behavior. The chat tool
  (`OpenAgents.Tools.IssueCapture`) and the authenticated API operation
  (`POST /api/v3/repos/:owner/:repo/issues/capture`) are two transports over
  it, so the two cannot drift: a refusal the tool gives is the refusal the API
  gives, and a draft the API writes is the draft the tool writes.

  Three things happen here, in this order, and the order matters.

  1. **The repository is resolved under the caller's own membership.** Nothing
     here mints authority. `authorize/2` asks
     `OpenAgents.Repositories.writable?/2` about the account that asked, and a
     caller who cannot write gets a typed refusal that names what is missing
     rather than a silent fallback to some other repository. A repository the
     caller cannot even see is reported as absent, because saying
     "you lack write access" about a private repository discloses that it
     exists.
  2. **A near-duplicate is preferred over a new row.** See `dedupe/2`.
  3. **Only then is an issue created**, through `OpenAgents.Issues.create_issue/3`
     with the caller as author. Going through that function rather than
     inserting directly is what subscribes the requester to the issue's own
     notifications: `create_issue/3` calls `Notifications.issue_opened/2`
     inside its transaction, so the requester follows the issue from the
     moment it exists.

  ## What the public issue says

  The body is a fixed template — outcome, current behavior, acceptance
  criteria — filled only from what the caller supplied. Nothing else reaches
  it. No conversation id, no message id, no prompt, no tool trace, no
  repository metadata, and no model output the caller did not see. The
  template placeholders are honest about being unfilled instead of inventing
  a current behavior nobody observed.
  """

  import Ecto.Changeset, only: [traverse_errors: 2]

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @maximum_statement_bytes 4_000
  @maximum_section_bytes 4_000
  @maximum_criteria 12
  @maximum_title_characters 72

  @type outcome :: :created | :existing
  @type result :: %{
          issue: Issue.t(),
          repository: Repository.t(),
          outcome: outcome()
        }
  @type error ::
          :blank_problem_statement
          | :problem_statement_too_long
          | :section_too_long
          | :invalid_repository
          | :repository_not_found
          | :repository_write_access_required
          | {:invalid_issue, map()}

  @doc """
  Captures `attrs` as an issue in `repository_path` on behalf of `actor`.

  `repository_path` is `owner/name`. `attrs` accepts string keys:

  - `"problem"` — required, the requester's own words.
  - `"current_behavior"` — optional.
  - `"acceptance_criteria"` — optional, a list of strings or a newline-separated
    string.

  Returns `{:ok, %{issue: issue, repository: repository, outcome: outcome}}`
  where `outcome` is `:created` for a new issue and `:existing` when
  deduplication matched one that was already open. Retrying the same statement
  against the same repository therefore returns the same issue rather than a
  second one.
  """
  @spec capture(User.t(), String.t(), map()) :: {:ok, result()} | {:error, error()}
  def capture(%User{} = actor, repository_path, attrs) when is_binary(repository_path) do
    with {:ok, problem} <- problem(attrs),
         {:ok, current_behavior} <- section(attrs, "current_behavior"),
         {:ok, criteria} <- criteria(attrs),
         {:ok, repository} <- authorize(actor, repository_path) do
      title = draft_title(problem)
      body = draft_body(problem, current_behavior, criteria)

      case dedupe(repository, title) do
        %Issue{} = existing ->
          {:ok, %{issue: existing, repository: repository, outcome: :existing}}

        nil ->
          create(actor, repository, title, body)
      end
    end
  end

  @doc """
  Resolves `repository_path` to a repository `actor` may write to.

  The two refusals are deliberately different facts. `:repository_not_found`
  means the caller cannot see it, and is also what a caller gets for a private
  repository they hold no membership in — the refusal must not become an
  existence oracle. `:repository_write_access_required` means the caller can
  see it and holds no writing role, which is safe to say because they already
  know it exists, and is the refusal that names the missing authority so the
  person knows what to ask for.
  """
  @spec authorize(User.t(), String.t()) :: {:ok, Repository.t()} | {:error, error()}
  def authorize(%User{} = actor, repository_path) when is_binary(repository_path) do
    with {:ok, owner, name} <- parse_path(repository_path),
         %Repository{} = repository <- Repositories.visible_by_path(owner, name, actor) do
      if Repositories.writable?(repository, actor) do
        {:ok, repository}
      else
        {:error, :repository_write_access_required}
      end
    else
      nil -> {:error, :repository_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The open issue this request should be folded into, or `nil`.

  **This is an exact match on the normalized title, not a semantic one, and
  that is a limitation rather than a preference.** The repository has no
  embedding index over issues: `OpenAgents.Tools.Embeddings` covers the tool
  catalog, and the pgvector tables under `OpenAgents.Memory.SemanticIndex`
  cover conversation messages. Neither indexes issue text, and standing one up
  is a larger change than this one.

  So the choice was between an exact normalized-title check and inventing
  keyword or substring heuristics. Heuristics are the worse failure: a
  substring match folds "search is slow" into "search is slow on mobile" and
  the second request disappears without anyone deciding it should. An exact
  match fails in the safe direction — it misses real duplicates, which a person
  can still close by hand, and it never swallows a distinct request.

  Normalization is case, punctuation, and whitespace only, so
  `"Add dark mode"`, `"add dark mode."`, and `"Add  dark   mode"` are one
  issue. When issue embeddings exist, this function is the single place that
  changes.
  """
  @spec dedupe(Repository.t(), String.t()) :: Issue.t() | nil
  def dedupe(%Repository{} = repository, title) when is_binary(title) do
    Issues.open_issue_with_normalized_title(repository, normalize_title(title))
  end

  @doc """
  The comparison form of a title: lowercase, alphanumeric runs, single spaces.

  `OpenAgents.Issues.open_issue_with_normalized_title/2` reproduces this in
  SQL. Change one and you must change the other, or deduplication silently
  stops matching.
  """
  @spec normalize_title(String.t()) :: String.t()
  def normalize_title(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  @doc "The title this statement drafts to, exposed so a preview can show it."
  @spec draft_title(String.t()) :: String.t()
  def draft_title(problem) when is_binary(problem) do
    problem
    |> collapse()
    |> first_sentence()
    |> truncate(@maximum_title_characters)
    |> capitalize_first()
  end

  @doc "The body this statement drafts to, exposed so a preview can show it."
  @spec draft_body(String.t(), String.t() | nil, [String.t()]) :: String.t()
  def draft_body(problem, current_behavior, criteria)
      when is_binary(problem) and is_list(criteria) do
    """
    ## Outcome

    #{collapse_lines(problem)}

    ## Current behavior

    #{current_behavior_section(current_behavior)}

    ## Acceptance criteria

    #{criteria_section(criteria)}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp create(actor, repository, title, body) do
    case Issues.create_issue(repository, %{"title" => title, "body" => body}, actor) do
      {:ok, %Issue{} = issue} ->
        {:ok, %{issue: issue, repository: repository, outcome: :created}}

      {:error, changeset} ->
        {:error, {:invalid_issue, changeset_errors(changeset)}}
    end
  end

  defp changeset_errors(changeset) do
    traverse_errors(changeset, fn {message, options} ->
      Regex.replace(~r/%\{(\w+)\}/, message, fn _whole, key ->
        options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp problem(attrs) do
    case attrs |> Map.get("problem") |> normalize_input() do
      nil ->
        {:error, :blank_problem_statement}

      problem when byte_size(problem) > @maximum_statement_bytes ->
        {:error, :problem_statement_too_long}

      problem ->
        {:ok, problem}
    end
  end

  defp section(attrs, key) do
    case attrs |> Map.get(key) |> normalize_input() do
      nil -> {:ok, nil}
      value when byte_size(value) > @maximum_section_bytes -> {:error, :section_too_long}
      value -> {:ok, value}
    end
  end

  defp criteria(attrs) do
    attrs
    |> Map.get("acceptance_criteria")
    |> List.wrap()
    |> Enum.flat_map(&String.split(to_string(&1), "\n"))
    |> Enum.map(&(&1 |> String.replace_prefix("- [ ]", "") |> String.replace_prefix("-", "")))
    |> Enum.map(&normalize_input/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@maximum_criteria)
    |> then(fn criteria ->
      if Enum.any?(criteria, &(byte_size(&1) > @maximum_section_bytes)) do
        {:error, :section_too_long}
      else
        {:ok, criteria}
      end
    end)
  end

  defp normalize_input(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_input(_value), do: nil

  defp current_behavior_section(nil),
    do: "Not recorded when this was captured. Fill this in before the work starts."

  defp current_behavior_section(current_behavior), do: collapse_lines(current_behavior)

  defp criteria_section([]),
    do: "- [ ] Not recorded when this was captured. Agree these before the work starts."

  defp criteria_section(criteria), do: Enum.map_join(criteria, "\n", &"- [ ] #{collapse(&1)}")

  defp parse_path(repository_path) do
    case repository_path |> String.trim() |> String.split("/", trim: true) do
      [owner, name] when byte_size(owner) in 1..100 and byte_size(name) in 1..100 ->
        {:ok, owner, name}

      _invalid ->
        {:error, :invalid_repository}
    end
  end

  defp collapse(value), do: value |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Paragraphs survive; runs of blank lines and trailing spaces do not. The
  # requester's own prose reaches the issue intact.
  defp collapse_lines(value) do
    value
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp first_sentence(value) do
    case String.split(value, ~r/(?<=[.!?])\s+/, parts: 2) do
      [sentence, _rest] -> String.trim(sentence)
      [whole] -> whole
    end
    |> String.trim_trailing(".")
  end

  defp truncate(value, limit) do
    if String.length(value) <= limit do
      value
    else
      value
      |> String.slice(0, limit)
      |> String.replace(~r/\s+\S*$/u, "")
      |> String.trim()
      |> then(fn trimmed ->
        if trimmed == "", do: String.slice(value, 0, limit), else: trimmed
      end)
    end
  end

  defp capitalize_first(""), do: ""

  defp capitalize_first(value) do
    {first, rest} = String.split_at(value, 1)
    String.upcase(first) <> rest
  end
end
