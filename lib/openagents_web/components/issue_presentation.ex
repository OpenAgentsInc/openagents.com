defmodule OpenAgentsWeb.Components.IssuePresentation do
  @moduledoc """
  How an `%OpenAgents.Issues.Issue{}` is drawn as a row, in one place.

  `OpenAgentsWeb.UI.Circle.issue_row/1` takes plain maps and atoms on purpose,
  so it can be rendered from a schema, an API payload, or a literal in a test.
  That leaves a translation layer — which state category a close reason maps
  to, which assignee of several the face shows, how an author with no account
  is named — and there is exactly one right answer to each. This module owns
  those answers so the repository list and the workspace-wide list cannot
  drift apart, and so a third list would inherit them rather than restate
  them.

  It renders the row and nothing else. Who may change an issue's state or its
  assignees is the caller's question: a caller with the authority passes
  controls through the `:state` and `:people` slots, and a caller without it
  passes none and gets the static glyphs.
  """
  use Phoenix.Component

  alias OpenAgents.Issues.Issue
  alias OpenAgentsWeb.UI.Circle

  attr :id, :string, required: true
  attr :issue, Issue, required: true
  attr :navigate, :any, required: true, doc: "where the title goes"

  attr :repository, :string,
    default: nil,
    doc: "`owner/name`; set it on a cross-repository list, leave it off within one"

  attr :progress, :string,
    default: nil,
    doc: "the derived `issue.openagents.progress` value, when the caller has read it"

  slot :state, doc: "a control that changes the issue's state, for a caller who may"
  slot :people, doc: "a control that changes the issue's assignees, for a caller who may"

  def issue_row(assigns) do
    ~H"""
    <Circle.issue_row
      id={@id}
      identifier={"##{@issue.number}"}
      repository={@repository}
      title={@issue.title}
      navigate={@navigate}
      status_category={category(@issue, @progress)}
      status_label={status_label(@issue, @progress)}
      labels={labels(@issue)}
      assignee={assignee(@issue)}
      created={"opened #{relative(@issue.inserted_at)} ago"}
      author={author(@issue)}
      comments={@issue.comments}
    >
      <:state :if={@state != []}>{render_slot(@state)}</:state>
      <:people :if={@people != []}>{render_slot(@people)}</:people>
    </Circle.issue_row>
    """
  end

  @doc """
  GitHub's state iconography, and one thing on top of it that the API already
  publishes.

  An open issue takes the green circle-dot. `not_planned` is the one close
  reason with a distinct reading, so it keeps the cancelled glyph; every other
  close is the purple check-circle.

  The exception is `in_progress`. An open issue a board says someone has
  started takes Circle's `:started` arc, which is the shape the component set
  has always drawn and never had data for. The value is the same derived
  `issue.openagents.progress` the API serves, read through the same reader's
  visibility, so the list and the API cannot show different work as underway.
  A caller that has not read progress passes none and gets GitHub's two states.
  """
  def category(issue, progress \\ nil)
  def category(%{state: "closed", state_reason: "not_planned"}, _progress), do: :canceled
  def category(%{state: "closed"}, _progress), do: :completed
  def category(%{state: "open"}, "in_progress"), do: :started
  def category(_issue, _progress), do: :open

  @doc "The word beside the glyph, for assistive technology and for a label."
  def status_label(issue, progress \\ nil)

  def status_label(%{state: "closed", state_reason: "not_planned"}, _progress),
    do: "Closed as not planned"

  def status_label(%{state: "closed"}, _progress), do: "Closed"
  def status_label(%{state: "open"}, "in_progress"), do: "In progress"
  def status_label(_issue, _progress), do: "Open"

  @doc """
  The states a triaging member may choose between.

  `duplicate` is rendered when it arrives from the API but is not offered: the
  menu has nowhere to record which issue it duplicates, and a duplicate that
  does not say of what is worse than a plain close.
  """
  def state_options do
    [
      {"Open", "open", nil},
      {"Closed as completed", "closed", "completed"},
      {"Closed as not planned", "closed", "not_planned"}
    ]
  end

  @doc "The close reason a menu should show as selected, defaulted like GitHub."
  def close_reason(%{state: "closed", state_reason: reason}), do: reason || "completed"
  def close_reason(_issue), do: nil

  @doc "Whether `login` is among the issue's assignees."
  def assigned?(issue, login), do: Enum.any?(issue.assignees || [], &(&1["login"] == login))

  @doc """
  The issue's labels, as the row wants them.

  A label carries a colour on GitHub; the row takes a tone from our ladder
  rather than that hex, so the list stays in one palette.
  """
  def labels(%{labels: labels}) when is_list(labels) do
    Enum.map(labels, fn label ->
      %{name: label["name"] || label[:name] || "label", tone: :neutral}
    end)
  end

  def labels(_issue), do: []

  @doc """
  The assignee the row's face shows.

  GitHub issues carry many assignees; the row shows the first, which is the one
  GitHub itself treats as `assignee`.
  """
  def assignee(%{assignees: [first | _rest]}) when is_map(first) do
    %{
      name: first["login"] || first[:login],
      src: first["avatar_url"] || first[:avatar_url],
      presence: :none
    }
  end

  def assignee(_issue), do: nil

  @doc """
  Who opened the issue.

  GitHub prints this beside when. An issue whose author is gone still has a
  history, so it says so rather than showing a blank.
  """
  def author(%{user: %{} = user}), do: user["login"] || user[:login] || "anonymous"
  def author(_issue), do: "anonymous"

  @doc "How long ago, coarsely: minutes, then hours, then days."
  def relative(nil), do: nil

  def relative(at) do
    at = if is_struct(at, NaiveDateTime), do: DateTime.from_naive!(at, "Etc/UTC"), else: at

    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 3_600 -> "#{max(div(s, 60), 1)}m"
      s when s < 86_400 -> "#{div(s, 3_600)}h"
      s -> "#{div(s, 86_400)}d"
    end
  end

  @doc "The `owner/name` a cross-repository row shows, from a preloaded issue."
  def repository_path(%{repository: %{owner: owner, name: name}}), do: "#{owner}/#{name}"
  def repository_path(_issue), do: nil
end
