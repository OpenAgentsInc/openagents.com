defmodule OpenAgentsWeb.LabelJSON do
  @moduledoc """
  Renders GitHub-compatible label JSON.
  """

  def render("index.json", %{labels: labels} = assigns) do
    %{labels: Enum.map(labels, &label_json(&1, assigns))}
  end

  def render("show.json", %{label: label} = assigns) do
    label_json(label, assigns)
  end

  def render("error.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp label_json(label, assigns) do
    owner = Map.get(assigns, :owner, "OpenAgents")
    repo = Map.get(assigns, :repo, "openagents")

    %{
      id: label.id,
      name: label.name,
      color: label.color,
      description: label.description,
      default: false,
      url: "https://openagents.com/api/v3/repos/#{owner}/#{repo}/labels/#{URI.encode_www_form(label.name)}"
    }
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
      to_string(Keyword.get(opts, String.to_existing_atom(key), key))
    end)
  end
end
