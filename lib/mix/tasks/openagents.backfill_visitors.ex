defmodule Mix.Tasks.OpenAgents.BackfillVisitors do
  @moduledoc """
  Backfills `visitors` and `conversations` for users created before the Sarah
  conversation schema was introduced.

  Run after `mix ecto.migrate`:

      mix openagents.backfill_visitors

  The task is idempotent: users that already have a visitor and conversation
  are skipped.

  No durable message data existed in the pre-Sarah `OpenAgents.Chat` module,
  so this task only creates the `visitors` and `conversations` rows (plus a
  single greeting message for new conversations).
  """

  use Mix.Task

  @shortdoc "Backfill visitors and conversations for existing users"

  @impl true
  def run(_args) do
    Application.ensure_all_started(:openagents)

    users = OpenAgents.Repo.all(OpenAgents.Accounts.User)

    Enum.each(users, fn user ->
      case OpenAgents.Conversations.ensure_conversation(user) do
        {:ok, _conversation} ->
          :ok

        {:error, reason} ->
          Mix.raise("Failed to backfill user #{user.id}: #{inspect(reason)}")
      end
    end)

    Mix.shell().info("Backfilled #{length(users)} existing user(s).")
  end
end
