defmodule OpenAgentsWeb.CommentJSON do
  @moduledoc """
  Renders GitHub-compatible issue comment JSON.
  """

  def render("index.json", %{comments: comments}) do
    %{comments: Enum.map(comments, &comment_json/1)}
  end

  def render("show.json", %{comment: comment}) do
    comment_json(comment)
  end

  def render("error.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp comment_json(comment) do
    %{
      id: comment.id,
      node_id: "IC_#{comment.id}",
      body: comment.body,
      user: comment.user,
      created_at: comment.created_at,
      updated_at: comment.updated_at
    }
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
      to_string(Keyword.get(opts, String.to_existing_atom(key), key))
    end)
  end
end
