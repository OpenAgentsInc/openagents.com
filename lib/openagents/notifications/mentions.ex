defmodule OpenAgents.Notifications.Mentions do
  @moduledoc """
  Reads `@login` out of issue and comment Markdown.

  Mention syntax is a bounded lexical field — the GitHub login grammar and
  nothing else — so it is parsed deterministically rather than interpreted. The
  parser resolves nothing on its own; `OpenAgents.Notifications` decides which
  of the extracted logins name an account that may read the repository.

  Fenced blocks and inline code spans are removed first, so a login inside a
  shell transcript or a code sample does not summon anybody.
  """

  # GitHub's own login grammar: alphanumerics and single inner hyphens, up to
  # 39 characters, never starting or ending with a hyphen.
  @mention ~r/(?<![A-Za-z0-9_@\/-])@([A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38})\b/

  @fenced ~r/^[ \t]*(```|~~~).*?(?:\n[ \t]*\1|\z)/ms
  @inline_code ~r/`[^`\n]*`/

  @doc """
  Every distinct login named in `body`, downcased, in the order it appears.

  Returns `[]` for a nil or blank body.
  """
  @spec extract(String.t() | nil) :: [String.t()]
  def extract(nil), do: []

  def extract(body) when is_binary(body) do
    body
    |> strip_code()
    |> then(&Regex.scan(@mention, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  def extract(_body), do: []

  defp strip_code(body) do
    body
    |> then(&Regex.replace(@fenced, &1, " "))
    |> then(&Regex.replace(@inline_code, &1, " "))
  end
end
