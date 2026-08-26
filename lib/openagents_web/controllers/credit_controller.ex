defmodule OpenAgentsWeb.CreditController do
  @moduledoc """
  `GET /api/v1/credit`: the inference money this account holds and has spent.

  The coder renders a balance from this rather than adding up what it saw,
  because what a turn spent is decided by the server that priced it: a client
  that kept its own total would be reporting one session's tokens as an
  account's spend, and would show the same figure to a second terminal that had
  already spent it.

  Four numbers and a flag, and the flag is the point. `remaining_microusd` is a
  ceiling rather than a balance while any of the account's calls landed on a
  model this deployment declares no rates for: an unpriced call records no
  cost, so it draws nothing down and the remainder does not move. `complete` is
  false exactly then, and `unpriced_calls` says how many calls the figure
  cannot see. A client that renders `remaining_microusd` without reading
  `complete` is a client that will show a full balance beside a session that
  spent all day (METER-001).
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Inference.Credit

  def show(conn, _params) do
    credit = Credit.account_credit(conn.assigns.current_user)

    json(conn, %{
      "credit" => %{
        "allowance_microusd" => credit.allowance_microusd,
        "spent_microusd" => credit.spent_microusd,
        "remaining_microusd" => credit.remaining_microusd,
        "unpriced_calls" => credit.unpriced_calls,
        "complete" => credit.complete?
      }
    })
  end
end
