defmodule OpenAgents.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  # Cloud memories: what an account explicitly asked the system to remember,
  # and what server-side consolidation later learns on its behalf. The store
  # is account-scoped and authoritative — unlike the disposable recall planes,
  # nothing else can rebuild it — so the row carries its own bounds rather
  # than trusting the context that writes it.
  #
  # A correction supersedes rather than edits: the replacement is a new row and
  # the old row's `superseded_by_id` points at it, so the chain a wrong memory
  # was fixed through stays readable.
  def up do
    create table(:memories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :bucket, :string, null: false
      add :body, :text, null: false

      # Where the memory came from: the thread or session that was open when
      # the reader asked for it. Nullable, because a memory written through the
      # API without a thread behind it is still a memory.
      add :source_ref, :string

      add :superseded_by_id, references(:memories, type: :binary_id, on_delete: :nilify_all)

      # The embedding of `body` under the active recall model, when the
      # embedding rail is configured. Nullable and advisory: recall falls back
      # to the lexical stand-in for every row that has none.
      add :embedding, {:array, :float}
      add :embedding_model, :string

      timestamps(type: :utc_datetime_usec)
    end

    # Recall reads one account's live memories, newest first, so the index it
    # uses excludes superseded rows rather than filtering them after the read.
    create index(:memories, [:user_id, :inserted_at],
             where: "superseded_by_id IS NULL",
             name: :memories_live_index
           )

    create index(:memories, [:superseded_by_id])

    create constraint(:memories, :memories_shape,
             check: """
             bucket IN ('user','learned')
             AND char_length(body) BETWEEN 1 AND 2000
             AND (source_ref IS NULL OR char_length(source_ref) BETWEEN 1 AND 200)
             AND (superseded_by_id IS NULL OR superseded_by_id <> id)
             """
           )

    # The lexical stand-in's index. It is generated and stored rather than
    # computed per query, and it is partial on the same predicate recall reads
    # under, so a superseded row costs nothing to keep.
    #
    # `english`, not `simple`, and the difference matters here in a way it does
    # not for `messages`. Conversation recall searches a phrase somebody typed;
    # this ranks a whole turn against a store, so under `simple` the turn's
    # stop words would match every memory the account holds and "shared
    # vocabulary" would stop meaning anything. Stemming earns its place for the
    # same reason: "the migration failed" should reach a memory about
    # migrations.
    execute("""
    ALTER TABLE memories
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(body, ''))) STORED
    """)

    execute("""
    CREATE INDEX memories_live_recall_gin_index
    ON memories USING GIN (search_vector)
    WHERE superseded_by_id IS NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS memories_live_recall_gin_index")
    drop table(:memories)
  end
end
