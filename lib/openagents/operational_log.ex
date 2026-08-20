defmodule OpenAgents.OperationalLog do
  @moduledoc "Reduces failures to bounded, content-free codes before logging or receipting."

  @spec code(term()) :: String.t()
  def code(reason) when is_atom(reason), do: bounded(Atom.to_string(reason))
  def code({tag, _detail}) when is_atom(tag), do: bounded(Atom.to_string(tag))
  def code({tag, _detail, _more}) when is_atom(tag), do: bounded(Atom.to_string(tag))

  def code(%{__struct__: module}) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore() |> bounded()
  end

  def code(_reason), do: "other"

  defp bounded(value), do: String.slice(value, 0, 64)
end
