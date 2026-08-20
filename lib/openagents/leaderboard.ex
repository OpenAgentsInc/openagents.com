defmodule OpenAgents.Leaderboard do
  @moduledoc """
  The public token leaderboard.

  PostgreSQL is authoritative (`INVARIANTS.md` DATA-001). This module reads the
  two tables that hold per-account token truth and publishes the bounded
  projection described by LEADERBOARD-001 — nothing else crosses the account
  boundary.

  ## Which usage counts

  `turn_receipts.usage` is already the merged total for a whole typed turn,
  including every tool-loop provider call, and `voice_sessions.usage` is already
  the merge of that session's responses. Summing `turn_provider_steps.usage` or
  `voice_response_receipts.usage` alongside them would double-count the same
  tokens. `tool_steps.usage` is an invocation count rather than tokens, and
  shadow-program runs are off-path under PROGRAM-002 and earn no credit. See
  `docs/LEADERBOARD.md`.

  ## Fan-out

  The board is public, so viewers are unbounded and anonymous. Reads never touch
  PostgreSQL per socket: `OpenAgents.Leaderboard.Server` coalesces invalidations,
  recomputes once, and pushes the same result to every local subscriber.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Conversations.Turn
  alias OpenAgents.Conversations.TurnReceipt
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Leaderboard.Entry
  alias OpenAgents.Leaderboard.Server
  alias OpenAgents.Repo
  alias OpenAgents.Voice.Session

  @topic "leaderboard"
  @invalidation_topic "leaderboard:invalidated"
  @default_limit 100

  @doc "The topic carrying computed board updates to local subscribers."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The topic carrying the content-free invalidation signal to every node."
  @spec invalidation_topic() :: String.t()
  def invalidation_topic, do: @invalidation_topic

  @doc "How many accounts the public board publishes."
  @spec limit() :: pos_integer()
  def limit, do: Application.get_env(:openagents, :leaderboard_limit, @default_limit)

  @doc """
  Subscribe to computed board updates.

  Delivers `{:leaderboard_updated, [%OpenAgents.Leaderboard.Entry{}]}`.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, @topic)

  @doc """
  Signal that some account's token total may have changed.

  Content-free and cheap: the recompute is coalesced and performed once by
  `OpenAgents.Leaderboard.Server`. Broadcast rather than a direct cast so every node
  refreshes the board it serves.
  """
  @spec invalidate() :: :ok
  def invalidate do
    Phoenix.PubSub.broadcast(OpenAgents.PubSub, @invalidation_topic, :leaderboard_invalidated)
    :ok
  end

  @doc "The current board, served from the single cached computation."
  @spec entries() :: [Entry.t()]
  def entries, do: Server.entries()

  @doc "Recompute the board now and push it to subscribers, bypassing the debounce."
  @spec refresh() :: [Entry.t()]
  def refresh, do: Server.refresh()

  @doc """
  Read the board straight from PostgreSQL.

  `entries/0` is the surface-facing call. This is the authoritative read behind
  the cache, exposed for the server and for tests that assert aggregation.
  """
  @spec compute_entries(pos_integer()) :: [Entry.t()]
  def compute_entries(row_limit \\ nil) do
    row_limit = row_limit || limit()

    ranked_query(row_limit)
    |> Repo.all()
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} ->
      %Entry{
        rank: rank,
        github_login: row.github_login,
        github_name: row.github_name,
        github_avatar_url: row.github_avatar_url,
        total_tokens: row.total_tokens
      }
    end)
  end

  defp ranked_query(row_limit) do
    from(user in User,
      join: total in subquery(account_totals()),
      on: total.user_id == user.id,
      where: user.status == "active",
      where: user.public_leaderboard_opted_out == false,
      where: total.tokens > 0,
      order_by: [desc: total.tokens, asc: user.inserted_at, asc: user.id],
      limit: ^row_limit,
      select: %{
        github_login: user.github_login,
        github_name: user.github_name,
        github_avatar_url: user.github_avatar_url,
        total_tokens: total.tokens
      }
    )
  end

  defp account_totals do
    from(row in subquery(union_all(typed_turn_usage(), ^voice_session_usage())),
      group_by: row.user_id,
      select: %{user_id: row.user_id, tokens: fragment("SUM(?)::bigint", row.tokens)}
    )
  end

  # Legacy pre-authentication browser visitors carry a NULL user_id and drop out
  # of the join, which is correct: DATA-002 says those rows are never claimed.
  defp typed_turn_usage do
    from(receipt in TurnReceipt,
      join: turn in Turn,
      on: turn.id == receipt.turn_id,
      join: conversation in Conversation,
      on: conversation.id == turn.conversation_id,
      join: visitor in Visitor,
      on: visitor.id == conversation.visitor_id,
      where: not is_nil(visitor.user_id),
      select: %{
        user_id: visitor.user_id,
        tokens:
          fragment(
            """
            GREATEST(
              CASE WHEN ? ->> 'total_tokens' ~ '^[0-9]+$' THEN (? ->> 'total_tokens')::bigint ELSE 0 END,
              CASE WHEN ? ->> 'input_tokens' ~ '^[0-9]+$' THEN (? ->> 'input_tokens')::bigint ELSE 0 END
                + CASE WHEN ? ->> 'output_tokens' ~ '^[0-9]+$' THEN (? ->> 'output_tokens')::bigint ELSE 0 END
            )
            """,
            receipt.usage,
            receipt.usage,
            receipt.usage,
            receipt.usage,
            receipt.usage,
            receipt.usage
          )
      }
    )
  end

  defp voice_session_usage do
    from(session in Session,
      join: conversation in Conversation,
      on: conversation.id == session.conversation_id,
      join: visitor in Visitor,
      on: visitor.id == conversation.visitor_id,
      where: not is_nil(visitor.user_id),
      select: %{
        user_id: visitor.user_id,
        tokens:
          fragment(
            """
            GREATEST(
              CASE WHEN ? ->> 'total_tokens' ~ '^[0-9]+$' THEN (? ->> 'total_tokens')::bigint ELSE 0 END,
              CASE WHEN ? ->> 'input_tokens' ~ '^[0-9]+$' THEN (? ->> 'input_tokens')::bigint ELSE 0 END
                + CASE WHEN ? ->> 'output_tokens' ~ '^[0-9]+$' THEN (? ->> 'output_tokens')::bigint ELSE 0 END
            )
            """,
            session.usage,
            session.usage,
            session.usage,
            session.usage,
            session.usage,
            session.usage
          )
      }
    )
  end
end
