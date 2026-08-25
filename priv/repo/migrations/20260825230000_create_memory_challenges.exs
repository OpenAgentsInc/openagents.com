defmodule OpenAgents.Repo.Migrations.CreateMemoryChallenges do
  use Ecto.Migration

  # Disagreement, as a record rather than an edit.
  #
  # A reader who finds an admitted system claim wrong needs a path other than
  # editing somebody else's row. That path is a **challenge**: an attributed,
  # dated row stating the ground, which suspends its target from recall when it
  # carries evidence of its own. A steward resolves it with a **refutation**,
  # which is another record. A reversal is a further record too; nothing here
  # is ever updated.
  #
  # This extends the table `20260825220000_create_system_memories.exs` created
  # rather than laying a second one beside it. That table already named all
  # three roles in its enum and wrote only `admission`; the columns below are
  # what the other two roles need.
  #
  # Three decisions are database predicates rather than changeset validations
  # (MEMORY-004):
  #
  #   * A refutation names a challenge, and a challenge on the very memory the
  #     refutation restores. The composite foreign key
  #     `(challenge_id, memory_id, challenge_role) -> (id, memory_id, role)`
  #     is what makes a refutation of an admission record, or of a challenge
  #     against some other memory, unrepresentable.
  #
  #   * Evidence belongs to a challenge and to nothing else, and a challenge's
  #     evidence list — when it carries one — has the same shape a system
  #     memory's does. An empty array is not "unevidenced": it is malformed,
  #     and the constraint refuses it, because reading it as absent is how an
  #     evidenced challenge would arrive claiming to suspend nothing.
  #
  #   * Each role's slug is the specification's: `adm:<memory>`, `chl:<memory>`,
  #     `ref:<challenge>`.
  #
  # Every column is asserted `IS NOT NULL` before it is compared. A check
  # constraint is satisfied when it evaluates to NULL, so a disjunct whose
  # columns are absent evaluates to NULL and carries the whole `OR` to NULL
  # unless some other disjunct is FALSE outright. Each branch below is guarded
  # by `role = '…'` first, and `role` is `NOT NULL`, so exactly one branch can
  # be anything but FALSE — and inside that branch nothing is compared before
  # it is asserted present.
  def up do
    # `steward_id` was the right name while `admission` was the only role: only
    # a steward admits. It is the wrong name now. Anyone may challenge, so the
    # column records who wrote the record, and the steward rule lives where a
    # refutation is written rather than in a column name that would have to lie
    # on two rows out of three.
    rename table(:memory_admissions), :steward_id, to: :author_id

    drop index(:memory_admissions, [:steward_id])
    create index(:memory_admissions, [:author_id])

    alter table(:memory_admissions) do
      # The challenge a refutation resolves. Null on every other role.
      add :challenge_id, :binary_id

      # Always the literal `challenge` on a refutation, and null elsewhere.
      # It exists so the foreign key below can insist that `challenge_id` names
      # a challenge; PostgreSQL will not put a literal in a foreign key, so the
      # literal is a column the check constraint pins.
      add :challenge_role, :string

      # A challenge's own evidence, and what makes it an *evidenced* challenge.
      # Null on an admission and on a refutation: the evidenced/unevidenced
      # distinction is defined for challenges only, and a column that means
      # nothing on the other two roles is a column nobody sets deliberately.
      add :evidence_refs, :jsonb
    end

    # What the composite foreign key points at.
    create unique_index(:memory_admissions, [:id, :memory_id, :role],
             name: :memory_admissions_id_memory_role_index
           )

    execute("""
    ALTER TABLE memory_admissions
    ADD CONSTRAINT memory_admissions_challenge_fkey
    FOREIGN KEY (challenge_id, memory_id, challenge_role)
    REFERENCES memory_admissions (id, memory_id, role) ON DELETE CASCADE
    """)

    drop constraint(:memory_admissions, :memory_admissions_shape)

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
                AND slug = 'adm:' || memory_id::text
                AND challenge_id IS NULL
                AND challenge_role IS NULL
                AND evidence_refs IS NULL)
               OR (role = 'challenge'
                AND verdict IS NULL
                AND slug = 'chl:' || memory_id::text
                AND challenge_id IS NULL
                AND challenge_role IS NULL
                AND (
                  evidence_refs IS NULL
                  OR (
                    jsonb_typeof(evidence_refs) = 'array'
                    AND jsonb_array_length(evidence_refs) BETWEEN 1 AND 20
                    AND NOT jsonb_path_exists(evidence_refs, '$[*] ? (!(@.type() == "object"
                          && exists(@.kind ? (@ == "receipt" || @ == "memory" || @ == "url"))
                          && exists(@.ref ? (@.type() == "string" && @ != ""))
                          && exists(@.digest ? (@.type() == "string" && @ != ""))))')
                  )
                ))
               OR (role = 'refutation'
                AND verdict IS NULL
                AND challenge_id IS NOT NULL
                AND challenge_role IS NOT NULL
                AND challenge_role = 'challenge'
                AND slug = 'ref:' || challenge_id::text
                AND evidence_refs IS NULL)
             )
             """
           )

    # Deriving a status reads every record for a memory and asks which
    # challenges are still open.
    create index(:memory_admissions, [:challenge_id])
    create index(:memory_admissions, [:role, :memory_id])
  end

  def down do
    drop index(:memory_admissions, [:role, :memory_id])
    drop index(:memory_admissions, [:challenge_id])

    drop constraint(:memory_admissions, :memory_admissions_shape)

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

    execute("ALTER TABLE memory_admissions DROP CONSTRAINT memory_admissions_challenge_fkey")

    drop index(:memory_admissions, [:id, :memory_id, :role],
           name: :memory_admissions_id_memory_role_index
         )

    alter table(:memory_admissions) do
      remove :evidence_refs
      remove :challenge_role
      remove :challenge_id
    end

    drop index(:memory_admissions, [:author_id])
    rename table(:memory_admissions), :author_id, to: :steward_id
    create index(:memory_admissions, [:steward_id])
  end
end
