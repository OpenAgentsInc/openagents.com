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

  @doc """
  The one bounded, content-free number a failure carries, when it has one.

  A code alone says a call failed; it cannot say whether the credential is
  wrong, the account is rate limited, or the provider is down — and those
  need different responses from an operator. An upstream HTTP status is the
  smallest thing that distinguishes them, and it is a status line rather than
  provider content, so it crosses the same boundary the code does.

  Anything that is not a plain HTTP status is `nil`: a detail that could carry
  a prompt, a key, or a body never reaches a log or a receipt through here.
  """
  @spec status(term()) :: pos_integer() | nil
  def status({_tag, status}) when is_integer(status) and status >= 100 and status <= 599,
    do: status

  def status(_reason), do: nil

  defp bounded(value), do: String.slice(value, 0, 64)
end
