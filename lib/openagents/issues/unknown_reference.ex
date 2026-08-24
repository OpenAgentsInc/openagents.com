defmodule OpenAgents.Issues.UnknownReference do
  @moduledoc """
  One name in a request body that the repository does not have.

  A label, an assignee, and a milestone arrive by name rather than by id, so
  writing an issue means resolving each of them, and each resolution can fail
  for a reason that has nothing to do with whether the caller may see the
  repository. Those lookups used to raise `Ecto.NoResultsError`, which is what
  the repository lookup raises too, so both failures left an API action by the
  same `404` — the same `404` the API returns deliberately for a repository a
  caller cannot see, so a client could not tell a privacy decision from a typo
  and the honest error was unreachable.

  This exception carries the field and the value it could not resolve, so the
  API answers `422` and names the offending label, login, or milestone number.
  """

  defexception [:field, :value, :message]

  @type t :: %__MODULE__{field: atom(), value: term(), message: String.t()}

  @doc """
  Raises for one name the repository does not have.

  The field is the request-body key a client sent, so the error names what the
  client wrote rather than the table that was read.
  """
  @spec raise!(:labels | :assignees | :milestone, term()) :: no_return()
  def raise!(field, value) do
    raise __MODULE__, field: field, value: value, message: sentence(field, value)
  end

  defp sentence(:labels, value),
    do: "#{quoted(value)} is not a label in this repository"

  defp sentence(:assignees, value),
    do: "#{quoted(value)} is not assignable in this repository"

  defp sentence(:milestone, value),
    do: "#{quoted(value)} is not a milestone in this repository"

  defp quoted(value) when is_binary(value), do: inspect(value)
  defp quoted(value), do: to_string(value)
end
