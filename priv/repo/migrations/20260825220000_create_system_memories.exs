defmodule OpenAgents.Repo.Migrations.CreateSystemMemories do
  use Ecto.Migration

  # The third memory bucket: what the network as a whole has learned, rather
  # than what one account asked to have remembered.
  #
  # A wrong `user` memory misleads one session. A wrong `system` memory would
  # reach every session, so the row carries the things that make a claim
  # answerable — who wrote it, when it was observed true, and what evidence
  # stands behind it — and the table refuses a row that carries none of them.
  #
  # Two decisions are load-bearing here, and both are database predicates
  # rather than changeset validations (MEMORY-004):
  #
  #   * A system candidate with an empty evidence list cannot exist. The write
  #     path refuses it too, but a constraint is what makes it unrepresentable
  #     rather than merely unwritten by the code that exists today.
  #
  #   * An admission record can only name a `system` row. The composite foreign
  #     key on `(id, bucket)` enforces that without any read of `memories`, so
  #     the admission path never issues a query across the account boundary
  #     MEMORY-010 draws.
  #
  # Rows in the `user` and `learned` buckets carry none of the system columns,
  # and the constraint says so in both directions.
  def up do
    alter table(:memories) do
      # `sys:` prefixed. The prefix is a routing convention, not a boundary —
      # the boundary is the admission record and the write authorization.
      add :slug, :string
      add :entity, :string

      # `ledger` or `glass`, never lower. A system memory's body reaches every
      # agent by definition, which is content plus metadata; a claim that
      # cannot ship its content is not a system memory.
      add :tier, :string

      # The date the claim was observed true, distinct from `inserted_at`.
      # `inserted_at` orders the chain; `as_of` dates the claim, so a stale
      # truth reads as dated rather than as current.
      add :as_of, :date

      # The author's own claim, and nothing more. Effective status is derived
      # from `memory_admissions`, so a row that says `admitted` with no steward
      # record behind it still reads as a candidate.
      add :admission, :string

      # A non-empty list of `{kind, ref, digest}`. `receipt` points at a forge
      # receipt, `memory` at a prior admitted row, `url` at public material;
      # the digest is what keeps evidence from being swapped after admission.
      add :evidence_refs, :jsonb
    end

    # The original shape constraint named two buckets. Recreating it is how the
    # third one becomes writable at all.
    drop constraint(:memories, :memories_shape)

    create constraint(:memories, :memories_shape,
             check: """
             bucket IN ('user','learned','system')
             AND char_length(body) BETWEEN 1 AND 2000
             AND (source_ref IS NULL OR char_length(source_ref) BETWEEN 1 AND 200)
             AND (superseded_by_id IS NULL OR superseded_by_id <> id)
             """
           )

    # The system columns, present together on a system row and absent together
    # on every other row. Stating the absent half matters as much as the
    # present half: it keeps a `user` row from quietly carrying a tier nothing
    # reads and nobody set deliberately.
    #
    # Every column is asserted `IS NOT NULL` before it is compared, and that is
    # not belt and braces. A check constraint passes when it evaluates to NULL,
    # so `tier IN ('ledger','glass')` alone admits a row with no tier at all,
    # and a length test alone admits a candidate whose evidence list is absent
    # rather than empty — which is the exact hole this constraint exists to
    # close.
    create constraint(:memories, :memories_system_shape,
             check: """
             (
               bucket <> 'system'
               AND slug IS NULL
               AND entity IS NULL
               AND tier IS NULL
               AND as_of IS NULL
               AND admission IS NULL
               AND evidence_refs IS NULL
             ) OR (
               bucket = 'system'
               AND slug IS NOT NULL
               AND slug LIKE 'sys:%'
               AND char_length(slug) BETWEEN 5 AND 200
               AND (entity IS NULL OR char_length(entity) BETWEEN 1 AND 200)
               AND tier IS NOT NULL
               AND tier IN ('ledger','glass')
               AND as_of IS NOT NULL
               AND admission IS NOT NULL
               AND admission IN ('candidate','admitted','rejected')
               AND evidence_refs IS NOT NULL
               AND jsonb_typeof(evidence_refs) = 'array'
               AND jsonb_array_length(evidence_refs) BETWEEN 1 AND 20
               AND NOT jsonb_path_exists(evidence_refs, '$[*] ? (!(@.type() == "object"
                     && exists(@.kind ? (@ == "receipt" || @ == "memory" || @ == "url"))
                     && exists(@.ref ? (@.type() == "string" && @ != ""))
                     && exists(@.digest ? (@.type() == "string" && @ != ""))))')
             )
             """
           )

    # What the composite foreign key below points at. A memory's bucket cannot
    # change out from under an admission record while one references it.
    create unique_index(:memories, [:id, :bucket], name: :memories_id_bucket_index)

    # Admission is a receipt, not a field the author sets.
    #
    # The record is a row of its own rather than a column on the candidate for
    # the reason a promise flip is a receipt rather than a flag: the account
    # that wrote the claim is not the account that may admit it, and the store
    # keeps every verdict rather than the last one written over the others.
    create table(:memory_admissions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The candidate this record judges, and the bucket it must be in. The
      # bucket rides the row so the composite foreign key can pin it.
      add :memory_id, :binary_id, null: false
      add :memory_bucket, :string, null: false

      # The account that wrote the record. A steward at the time of the write;
      # the row records who, and the role check runs where the row is created.
      add :steward_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # `adm:<memory_id>` for an admission. The slug namespace is the spec's;
      # `chl:` and `ref:` join it when challenge and refutation land.
      add :slug, :string, null: false

      # `admission` today. `challenge` and `refutation` are named here because
      # they are the same enum, not because this issue writes them.
      add :role, :string, null: false

      # `admitted` or `rejected` on an admission record.
      add :verdict, :string

      # Why. A verdict without a ground cannot be argued with.
      add :ground, :text, null: false

      # Append-only: inserted, never updated, so there is no `updated_at`.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute("""
    ALTER TABLE memory_admissions
    ADD CONSTRAINT memory_admissions_memory_fkey
    FOREIGN KEY (memory_id, memory_bucket)
    REFERENCES memories (id, bucket) ON DELETE CASCADE
    """)

    create constraint(:memory_admissions, :memory_admissions_shape,
             check: """
             memory_bucket = 'system'
             AND role IN ('admission','challenge','refutation')
             AND char_length(slug) BETWEEN 1 AND 200
             AND char_length(ground) BETWEEN 1 AND 2000
             AND (
               (role = 'admission'
                AND verdict IS NOT NULL
                AND verdict IN ('admitted','rejected')
                AND slug = 'adm:' || memory_id::text)
               OR (role <> 'admission' AND verdict IS NULL)
             )
             """
           )

    # Deriving a candidate's status reads its records newest last.
    create index(:memory_admissions, [:memory_id, :inserted_at])
    create index(:memory_admissions, [:steward_id])
  end

  def down do
    drop table(:memory_admissions)
    drop constraint(:memories, :memories_system_shape)
    drop index(:memories, [:id, :bucket], name: :memories_id_bucket_index)
    drop constraint(:memories, :memories_shape)

    create constraint(:memories, :memories_shape,
             check: """
             bucket IN ('user','learned')
             AND char_length(body) BETWEEN 1 AND 2000
             AND (source_ref IS NULL OR char_length(source_ref) BETWEEN 1 AND 200)
             AND (superseded_by_id IS NULL OR superseded_by_id <> id)
             """
           )

    alter table(:memories) do
      remove :slug
      remove :entity
      remove :tier
      remove :as_of
      remove :admission
      remove :evidence_refs
    end
  end
end
