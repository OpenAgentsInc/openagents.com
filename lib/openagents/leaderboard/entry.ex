defmodule OpenAgents.Leaderboard.Entry do
  @moduledoc """
  One published row of the public leaderboard.

  This struct is the whole published projection. `INVARIANTS.md` LEADERBOARD-001
  binds the board to a rank, the GitHub display fields already shown in the
  account chrome, and one non-negative integer token total. Anything absent from
  these fields is deliberately absent: no conversation, turn, receipt, or session
  identifier, no model identifier, no message or recall content, no activity
  timestamp, no text/voice split, and no priced cost.

  Adding a field here publishes it to the internet, so treat this struct as the
  contract rather than as a convenience payload.
  """

  @enforce_keys [:rank, :github_login, :github_name, :github_avatar_url, :total_tokens]
  defstruct [:rank, :github_login, :github_name, :github_avatar_url, :total_tokens]

  @type t :: %__MODULE__{
          rank: pos_integer(),
          github_login: String.t(),
          github_name: String.t() | nil,
          github_avatar_url: String.t(),
          total_tokens: non_neg_integer()
        }

  @doc """
  The name to lead with, qualified by the handle in the surface.

  Matches the account chrome: GitHub name when present, otherwise the handle
  stands alone rather than rendering an empty line.
  """
  @spec display_name(t()) :: String.t() | nil
  def display_name(%__MODULE__{github_name: name}) when is_binary(name) do
    if String.trim(name) == "", do: nil, else: name
  end

  def display_name(%__MODULE__{}), do: nil
end
