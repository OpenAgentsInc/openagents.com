defmodule OpenAgents.Accounts.OperatorConfig do
  @moduledoc "Parses the bounded GitHub identity allowlist for operator surfaces."

  @maximum_operators 32

  @spec parse_github_ids!(String.t() | nil) :: [pos_integer()]
  def parse_github_ids!(nil), do: []

  def parse_github_ids!(encoded) when is_binary(encoded) do
    ids =
      encoded
      |> String.split(",", trim: true)
      |> Enum.map(&parse_id!/1)
      |> Enum.uniq()

    if ids == [] or length(ids) > @maximum_operators do
      raise ArgumentError,
            "OPENAGENTS_ADMIN_GITHUB_IDS must contain between 1 and #{@maximum_operators} IDs"
    end

    ids
  end

  def parse_github_ids!(_invalid) do
    raise ArgumentError, "OPENAGENTS_ADMIN_GITHUB_IDS must be a comma-separated list"
  end

  defp parse_id!(encoded) do
    case Integer.parse(String.trim(encoded)) do
      {id, ""} when id > 0 -> id
      _invalid -> raise ArgumentError, "OPENAGENTS_ADMIN_GITHUB_IDS contains an invalid ID"
    end
  end
end
