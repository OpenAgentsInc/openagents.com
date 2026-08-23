defmodule OpenAgentsWeb.StackJSON do
  @moduledoc "Renders pull request stacks with their ordered entries."

  def render("index.json", %{stacks: stacks} = assigns),
    do: Enum.map(stacks, &stack(&1, assigns))

  def render("show.json", %{stack: stack} = assigns) do
    json = stack(stack, assigns)

    case Map.get(assigns, :replay_state) do
      nil -> json
      replay_state -> Map.put(json, :replayed, replay_state == :replayed)
    end
  end

  defp stack(stack, assigns) do
    base_url = String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")
    owner = assigns.owner
    repo = assigns.repo

    %{
      id: stack.id,
      number: stack.number,
      trunk_ref: stack.trunk_ref,
      state: stack.state,
      health: stack.health,
      version: stack.version,
      size: length(stack.entries),
      entries: Enum.map(stack.entries, &entry(&1, owner, repo, base_url)),
      created_at: stack.inserted_at,
      updated_at: stack.updated_at,
      url: "#{base_url}/api/v3/repos/#{owner}/#{repo}/stacks/#{stack.number}"
    }
  end

  defp entry(entry, owner, repo, base_url) do
    pull_request = entry.pull_request

    %{
      position: entry.position,
      boundary_oid: entry.boundary_oid,
      observed_head_oid: entry.observed_head_oid,
      pull_request: %{
        number: pull_request.issue.number,
        state: pull_request.issue.state,
        head: %{ref: pull_request.head_ref, sha: pull_request.head_sha},
        base: %{ref: pull_request.base_ref, sha: pull_request.base_sha},
        url: "#{base_url}/api/v3/repos/#{owner}/#{repo}/pulls/#{pull_request.issue.number}"
      }
    }
  end
end
