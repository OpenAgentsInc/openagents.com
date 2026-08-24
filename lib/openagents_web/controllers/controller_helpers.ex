defmodule OpenAgentsWeb.ControllerHelpers do
  @moduledoc """
  Shared helpers for the JSON API controllers.
  """

  @doc """
  Parses a numeric path segment, treating a malformed value as a missing row.

  Controllers already rescue `Ecto.NoResultsError` into a stable 404, so a
  non-integer identifier takes the same path instead of crashing with an
  `ArgumentError`.
  """
  @spec integer_param!(term()) :: integer()
  def integer_param!(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _malformed -> raise Ecto.NoResultsError, queryable: "parameter"
    end
  end

  def integer_param!(value) when is_integer(value), do: value

  @doc """
  Runs one lookup that may not resolve, and tags the outcome.

  Every bang lookup raises `Ecto.NoResultsError`, so a `rescue` wrapped around a
  whole controller action catches all of them at once: the repository the caller
  may not see, and, further in, a label a request body named. Two unrelated
  failures then leave by the same `404` — and because `404` is the answer the
  API gives deliberately for a repository a caller cannot see, the second
  failure is not just mislabelled, it is unreadable. A caller cannot tell a
  privacy decision from a typo.

  Wrapping one lookup keeps the rescue the width of the thing it was written
  for, so an `Ecto.NoResultsError` raised anywhere else keeps its own meaning
  rather than silently joining this one.

      with {:ok, repository} <- lookup(fn -> Repositories.get_visible_by_path!(owner, repo, reader) end) do
        ...
      else
        {:error, :not_found} -> ApiError.not_found(conn)
      end
  """
  @spec lookup((-> term())) :: {:ok, term()} | {:error, :not_found}
  def lookup(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end
end
