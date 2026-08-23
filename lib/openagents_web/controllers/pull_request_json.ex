defmodule OpenAgentsWeb.PullRequestJSON do
  @moduledoc "Renders pull requests in a GitHub-compatible shape."

  def render("index.json", %{pull_requests: pull_requests} = assigns),
    do: Enum.map(pull_requests, &pull_request(&1, assigns))

  def render("show.json", %{pull_request: pull_request} = assigns),
    do: pull_request(pull_request, assigns)

  defp pull_request(pr, assigns) do
    base_url = String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")
    owner = assigns.owner
    repo = assigns.repo

    %{
      id: pr.id,
      number: pr.issue.number,
      title: pr.issue.title,
      body: pr.issue.body,
      state: pr.issue.state,
      draft: pr.draft,
      user: pr.issue.user,
      merged: not is_nil(pr.merged_at),
      head: %{
        ref: pr.head_ref,
        sha: pr.head_sha,
        repo: %{full_name: "#{pr.head_repository.owner}/#{pr.head_repository.name}"}
      },
      base: %{ref: pr.base_ref, sha: pr.base_sha, repo: %{full_name: "#{owner}/#{repo}"}},
      stack: stack_context(pr, assigns),
      created_at: pr.inserted_at,
      updated_at: pr.updated_at,
      html_url: "#{base_url}/#{owner}/#{repo}/pulls/#{pr.issue.number}",
      url: "#{base_url}/api/v3/repos/#{owner}/#{repo}/pulls/#{pr.issue.number}"
    }
  end

  # Stack membership: the stack number, this layer's position, the active
  # size, the stack health, and the effective base — the stack trunk that
  # governs policy — or `nil` for an unstacked pull request.
  defp stack_context(pr, assigns) do
    assigns
    |> Map.get(:stack_contexts, %{})
    |> Map.get(pr.id)
  end
end
