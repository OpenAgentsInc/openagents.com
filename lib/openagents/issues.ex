defmodule OpenAgents.Issues do
  @moduledoc """
  The Issues context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Repo
  alias OpenAgents.Issues.Issue

  def list_issues(opts \\ []) do
    state = Keyword.get(opts, :state, "open")

    Issue
    |> maybe_filter_state(state)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_issue!(id), do: Repo.get!(Issue, id)

  def get_issue_by_number!(number) when is_integer(number),
    do: Repo.get_by!(Issue, number: number)

  def create_issue(attrs \\ %{}) do
    number = next_issue_number()
    normalized = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    %Issue{}
    |> Issue.changeset(Map.put(normalized, "number", number))
    |> Repo.insert()
  end

  def update_issue(%Issue{} = issue, attrs) do
    attrs = maybe_closed_attrs(issue, attrs)

    issue
    |> Issue.changeset(attrs)
    |> Repo.update()
  end

  def change_issue(%Issue{} = issue, attrs \\ %{}) do
    Issue.changeset(issue, attrs)
  end

  defp maybe_closed_attrs(issue, %{"state" => "closed"} = attrs) do
    if issue.state == "open" do
      attrs
      |> Map.put("closed_at", DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.put_new("state_reason", "completed")
    else
      attrs
    end
  end

  defp maybe_closed_attrs(_issue, %{state: "closed"} = attrs) do
    if is_nil(attrs[:closed_at]) do
      Map.put(attrs, :closed_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      attrs
    end
    |> Map.put_new(:state_reason, "completed")
  end

  defp maybe_closed_attrs(_issue, %{"state" => "open"} = attrs) do
    attrs
    |> Map.put("closed_at", nil)
    |> Map.put("state_reason", nil)
  end

  defp maybe_closed_attrs(_issue, %{state: "open"} = attrs) do
    attrs
    |> Map.put(:closed_at, nil)
    |> Map.put(:state_reason, nil)
  end

  defp maybe_closed_attrs(_issue, attrs), do: attrs

  defp maybe_filter_state(query, "all"), do: query
  defp maybe_filter_state(query, state), do: where(query, state: ^state)

  defp next_issue_number do
    case Repo.aggregate(Issue, :max, :number) do
      nil -> 1
      n -> n + 1
    end
  end
end
