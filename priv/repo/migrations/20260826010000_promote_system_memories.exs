defmodule OpenAgents.Repo.Migrations.PromoteSystemMemories do
  use Ecto.Migration

  # The drain from the memory store into the knowledge base, and the line that
  # keeps the two from becoming rival stores of one claim.
  #
  # Specification section 8 draws the line — the knowledge base owns what the
  # project has reviewed and decided, memory owns what the network has observed
  # and can evidence — and states two rules over it. The first is that promotion
  # drains memory into the knowledge base: a stabilized claim becomes a reviewed
  # stance, and the row it came from is superseded by a **promotion tombstone**
  # whose body names that stance, so the claim has exactly one live home. The
  # second is that the knowledge base wins a recall collision.
  #
  # This migration implements the first rule and makes the second one moot for
  # every claim the first covers. `docs/memory/knowledge-base-boundary.md`
  # carries the reasoning; the short version is that a claim is "the same claim"
  # across the two rails only when a promotion recorded the link, and once a
  # promotion has recorded it the memory half is no longer a live admitted row
  # for recall to collide with.
  #
  # Two decisions are database predicates rather than changeset validations
  # (MEMORY-004):
  #
  #   * **A tombstone names its stance.** `position(stance in body) > 0` is what
  #     makes "whose body names the stance" a shape rather than a convention the
  #     writing code happens to follow today. A tombstone that pointed nowhere
  #     would leave a reader holding a claim with no live home at all.
  #
  #   * **A tombstone is not a claim, so no record may name one.** The composite
  #     foreign key `(memory_id, memory_promoted) -> memories (id, promoted)`,
  #     with `memory_promoted` pinned to `false` by the shape constraint, is
  #     what makes an admission, a challenge, or a refutation against a
  #     tombstone unrepresentable. That is the load-bearing half: recall
  #     surfaces admitted rows only (specification 7.1), so a row that can never
  #     be admitted can never be recalled, and the promoted claim's one live
  #     home is the stance.
  #
  # The pinned literal is the same device `challenge_role` already uses:
  # PostgreSQL will not put a literal in a foreign key, so the literal is a
  # column the check constraint holds down.
  def up do
    alter table(:memories) do
      # The knowledge-base stance this claim was promoted to, and the only
      # cross-rail identifier either rail has. It is the `id` field of a record
      # in the knowledge-base corpus (`plugins/knowledge-base/kb/stances.json`
      # in `OpenAgentsInc/openagents`), which is kebab-case and stable across
      # regenerations of the compiled plugin.
      #
      # A row carrying one is a promotion tombstone. Null on every other row,
      # system or otherwise.
      add :stance, :string
    end

    # Whether this row is a promotion tombstone, as a column a foreign key can
    # reference. Generated rather than written, so it cannot disagree with
    # `stance`, and stored rather than virtual, so it can be indexed.
    execute(
      """
      ALTER TABLE memories
      ADD COLUMN promoted boolean
      GENERATED ALWAYS AS (stance IS NOT NULL) STORED
      """,
      "ALTER TABLE memories DROP COLUMN promoted"
    )

    drop constraint(:memories, :memories_system_shape)

    # The system shape, extended in both directions: `stance` is refused
    # outright on a `user` or `learned` row, and on a system row it is either
    # absent or a well-formed stance id that the body names.
    #
    # Every column is asserted `IS NOT NULL` before it is compared, for the
    # reason the constraint this replaces gives: a check constraint passes when
    # it evaluates to NULL, so a format test alone would admit a tombstone whose
    # stance is absent rather than malformed.
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
               AND stance IS NULL
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
               AND (
                 stance IS NULL
                 OR (
                   char_length(stance) BETWEEN 1 AND 200
                   AND stance ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
                   AND position(stance in body) > 0
                 )
               )
             )
             """
           )

    # What the composite foreign key below points at.
    create unique_index(:memories, [:id, :promoted], name: :memories_id_promoted_index)

    # Reading the store's promotion tombstones without scanning it.
    create index(:memories, [:stance], where: "stance IS NOT NULL")

    alter table(:memory_admissions) do
      # Always `false`. It exists so the foreign key below can insist that
      # `memory_id` names a memory that is not a promotion tombstone; the shape
      # constraint pins the literal.
      add :memory_promoted, :boolean, null: false, default: false
    end

    execute(
      """
      ALTER TABLE memory_admissions
      ADD CONSTRAINT memory_admissions_promotion_fkey
      FOREIGN KEY (memory_id, memory_promoted)
      REFERENCES memories (id, promoted) ON DELETE CASCADE
      """,
      "ALTER TABLE memory_admissions DROP CONSTRAINT memory_admissions_promotion_fkey"
    )

    drop constraint(:memory_admissions, :memory_admissions_shape)

    create constraint(:memory_admissions, :memory_admissions_shape,
             check: """
             memory_bucket = 'system'
             AND memory_promoted = false
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
  end

  def down do
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

    execute("ALTER TABLE memory_admissions DROP CONSTRAINT memory_admissions_promotion_fkey")

    alter table(:memory_admissions) do
      remove :memory_promoted
    end

    drop index(:memories, [:stance], where: "stance IS NOT NULL")
    drop index(:memories, [:id, :promoted], name: :memories_id_promoted_index)
    drop constraint(:memories, :memories_system_shape)

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

    execute("ALTER TABLE memories DROP COLUMN promoted")

    alter table(:memories) do
      remove :stance
    end
  end
end
