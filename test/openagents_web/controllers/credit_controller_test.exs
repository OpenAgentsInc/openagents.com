defmodule OpenAgentsWeb.CreditControllerTest do
  @moduledoc """
  `GET /api/v1/credit`: what the coder's status bar reads.

  The reason this endpoint exists, rather than a client keeping its own total,
  is that spend is the server's: it prices the call, and a second terminal on
  the same account spends the same money. The reason it carries `complete` is
  METER-001 — an unpriced call records no cost, so the remainder does not move,
  and a client that rendered the remainder alone would show a full balance
  beside a session that had run all day.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Credit
  alias OpenAgents.Repo
  alias OpenAgents.Threads

  # `put_chat_api_token/2` mints the token for this account, so naming the key
  # the same way is how a test reaches the user behind the credential it sent.
  defp account(key), do: github_user("api-token-" <> key)

  defp output_tokens_costing(microusd) do
    div(
      microusd * 1_000,
      Application.fetch_env!(:openagents, :inference_output_price_microusd_per_ktoken)
    )
  end

  defp minted(visitor_id) do
    {:ok, thread} = Threads.open(%Visitor{id: visitor_id}, "spend some credit")
    {:ok, _fenced, grant, _token} = Threads.mint_grant(thread)
    grant
  end

  test "a new account reads its whole grant, with nothing unseen", %{conn: conn} do
    body =
      conn
      |> put_chat_api_token("credit-fresh")
      |> get(~p"/api/v1/credit")
      |> json_response(200)

    assert body["credit"]["allowance_microusd"] == Credit.new_account_allowance()
    assert body["credit"]["spent_microusd"] == 0
    assert body["credit"]["remaining_microusd"] == Credit.new_account_allowance()
    assert body["credit"]["unpriced_calls"] == 0
    assert body["credit"]["complete"] == true
  end

  test "priced spend comes off the remainder", %{conn: conn} do
    owner = "credit-spent" |> account() |> Conversations.ensure_owner_visitor()

    {:ok, _metered} =
      Inference.record_usage(minted(owner.id), %{
        "output_tokens" => output_tokens_costing(1_600_000)
      })

    body =
      conn
      |> put_chat_api_token("credit-spent")
      |> get(~p"/api/v1/credit")
      |> json_response(200)

    assert body["credit"]["spent_microusd"] == 1_600_000

    assert body["credit"]["remaining_microusd"] ==
             Credit.new_account_allowance() - 1_600_000

    assert body["credit"]["complete"] == true
  end

  # The path the coder's own lane is on today. The figure does not move, and
  # the response has to say why rather than leave the client to discover it.
  test "an unpriced call leaves the remainder still and says so", %{conn: conn} do
    owner = "credit-unpriced" |> account() |> Conversations.ensure_owner_visitor()
    luna = Application.fetch_env!(:openagents, :openai_model)

    {:ok, thread} = Threads.open(%Visitor{id: owner.id}, "Run the unpriced lane", model: luna)
    {:ok, _fenced, grant, _token} = Threads.mint_grant(thread)
    {:ok, _metered} = Inference.record_usage(grant, %{"output_tokens" => 500_000})

    body =
      conn
      |> put_chat_api_token("credit-unpriced")
      |> get(~p"/api/v1/credit")
      |> json_response(200)

    assert body["credit"]["spent_microusd"] == 0
    assert body["credit"]["remaining_microusd"] == Credit.new_account_allowance()
    assert body["credit"]["unpriced_calls"] == 1
    assert body["credit"]["complete"] == false
  end

  test "an account holding a grandfathered allowance reads its own figure", %{conn: conn} do
    user = account("credit-grandfathered-api")

    {1, nil} =
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        set: [credit_allowance_microusd: 100_000_000]
      )

    body =
      conn
      |> put_chat_api_token("credit-grandfathered-api")
      |> get(~p"/api/v1/credit")
      |> json_response(200)

    assert body["credit"]["allowance_microusd"] == 100_000_000
    assert body["credit"]["remaining_microusd"] == 100_000_000
  end

  test "an anonymous caller is refused rather than shown an account", %{conn: conn} do
    assert conn |> get(~p"/api/v1/credit") |> json_response(401)
  end
end
