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
end
