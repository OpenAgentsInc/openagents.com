defmodule OpenAgents.Repo.Migrations.AddLaneToThreads do
  @moduledoc """
  Which lane opened the thread, and therefore whether it can hold authority.

  Two lanes, by check constraint:

    * `thread` — the granted lane. The model is an admitted catalog id and the
      open mints a grant against the account's credit. Default.
    * `local`  — the transcript-only lane. The model is the vendor string a
      local runtime serves (`ollama:...`), bounded but never admitted against
      the catalog, and no grant is ever minted: the thread exists so a local
      run leaves the same durable transcript a granted run does.

  The default is `thread` rather than `NULL` because it is the honest history:
  every thread written before this column existed came through the granted
  lane — its model was catalog-admitted and its open minted a grant — so
  backfilling `thread` records what actually happened rather than an absence
  (issue #243).
  """

  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :lane, :text, null: false, default: "thread"
    end

    create constraint(:threads, :threads_lane_check, check: "lane IN ('thread', 'local')")
  end
end
