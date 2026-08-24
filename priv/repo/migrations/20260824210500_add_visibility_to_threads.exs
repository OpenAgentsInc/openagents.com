defmodule OpenAgents.Repo.Migrations.AddVisibilityToThreads do
  @moduledoc """
  The transparency tier that governs who may read a thread's transcript.

  The vocabulary is the one this application already uses for disclosure —
  `dark`, `pulse`, `ledger`, `glass` (`OpenAgents.Transparency`,
  `OpenAgents.Forge.Visibility`, `docs/taxonomy.md`) — not a second ladder. The
  check constraint admits only the two rungs this surface can enforce today:

    * `dark`   — the account that opened the thread, and nobody else. Default.
    * `ledger` — content and metadata: any signed-in reader holding the
      thread's id may read the transcript.

  `pulse` (metadata only) and `glass` (full access) are in the vocabulary and
  have no thread surface behind them, so the column refuses them rather than
  storing a tier no read path applies. Widening is a deliberate act at open
  and is recorded in the transcript as `thread.visibility_set` (THREAD-002).

  The default is the narrow rung, so every thread written before this migration
  becomes owner-only rather than inheriting a widening nobody asked for.
  """

  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :visibility, :text, null: false, default: "dark"
    end

    create constraint(:threads, :threads_visibility_check,
             check: "visibility IN ('dark', 'ledger')"
           )
  end
end
