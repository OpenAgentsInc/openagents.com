defmodule OpenAgentsWeb.ProjectJSON do
  @moduledoc """
  Renders GitHub-compatible project and project item JSON.
  """

  def render("index.json", %{projects: projects}) do
    %{projects: Enum.map(projects, &project_json/1)}
  end

  def render("show.json", %{project: project}) do
    project_json(project)
  end

  def render("items.json", %{items: items} = assigns) do
    item_projections = Map.get(assigns, :item_projections, %{})

    %{
      items: Enum.map(items, &item_json(&1, Map.get(item_projections, &1.id)))
    }
  end

  def render("events.json", %{events: events, pagination: pagination}) do
    %{
      events: Enum.map(events, &event_json/1),
      pagination: %{
        page: pagination.page,
        per_page: pagination.per_page,
        total: pagination.total,
        total_pages: total_pages(pagination.total, pagination.per_page)
      }
    }
  end

  def render("fields.json", %{fields: fields}) do
    %{fields: Enum.map(fields, &field_json/1)}
  end

  def render("notes.json", %{notes: notes, page: page, total_count: total_count}) do
    %{
      notes: Enum.map(notes, &note_json/1),
      page: page,
      per_page: OpenAgents.Projects.notes_per_page(),
      total_count: total_count
    }
  end

  def render("note.json", %{note: note}) do
    note_json(note)
  end

  def render("error.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp project_json(project) do
    %{
      id: project.id,
      number: project.number,
      title: project.title,
      # `description` is the canonical project-context field, and it is
      # Markdown. Nothing renders it server-side for the API; a client renders
      # it the same way it renders an issue body.
      description: project.description,
      owner: project.owner,
      state: project.state,
      created_at: project.inserted_at,
      updated_at: project.updated_at
    }
  end

  defp note_json(note) do
    %{
      id: note.id,
      kind: note.kind,
      body: note.body,
      author: note.author,
      created_at: note.inserted_at,
      updated_at: note.updated_at
    }
  end

  defp item_json(item, item_projection) do
    issue = item.issue
    repository = issue.repository
    base_url = OpenAgentsWeb.Endpoint.url()
    values = get_in(item_projection || %{}, [:values]) || item.values
    promise = get_in(item_projection || %{}, [:promise])

    %{
      id: item.id,
      issue_id: item.issue_id,
      issue: %{
        owner: repository.owner,
        repo: repository.name,
        number: issue.number,
        url:
          "#{base_url}/api/v3/repos/#{repository.owner}/#{repository.name}/issues/#{issue.number}",
        html_url: "#{base_url}/#{repository.owner}/#{repository.name}/issues/#{issue.number}"
      },
      values: values
    }
    |> maybe_put_promise(promise)
  end

  defp maybe_put_promise(json, nil), do: json
  defp maybe_put_promise(json, promise), do: Map.put(json, :openagents, %{promise: promise})

  defp event_json(event) do
    %{
      id: event.id,
      project_item_id: event.project_item_id,
      project_id: event.project_id,
      actor_login: event.actor_login,
      actor_user_id: event.actor_user_id,
      kind: event.kind,
      from_state: event.from_state,
      to_state: event.to_state,
      changes: event.changes,
      occurred_at: event.occurred_at,
      inserted_at: event.inserted_at
    }
  end

  defp total_pages(0, _per_page), do: 1
  defp total_pages(total, per_page), do: ceil(total / per_page)

  defp field_json(field) do
    %{
      id: field.id,
      name: field.name,
      data_type: field.data_type,
      options: field.options
    }
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
      to_string(Keyword.get(opts, String.to_existing_atom(key), key))
    end)
  end
end
