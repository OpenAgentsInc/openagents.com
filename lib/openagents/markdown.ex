defmodule OpenAgents.Markdown do
  @moduledoc """
  Thin Markdown wrapper over `MDEx`.

  Replaces the retired `Earmark` pipeline used by OpenAgents.
  """

  @spec to_html(String.t(), keyword()) :: String.t()
  def to_html(text, _opts \\ []) do
    text = if is_binary(text), do: text, else: ""
    MDEx.to_html!(text, format: :html)
  rescue
    _ -> text
  end

  @spec render(String.t()) :: String.t()
  def render(text), do: to_html(text)

  @spec parse(String.t()) :: {:ok, String.t()}
  def parse(text) do
    {:ok, to_html(text)}
  end
end
