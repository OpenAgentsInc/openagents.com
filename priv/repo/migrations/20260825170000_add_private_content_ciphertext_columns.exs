defmodule OpenAgents.Repo.Migrations.AddPrivateContentCiphertextColumns do
  @moduledoc """
  The expand half of sealing the private content columns nobody searches
  (issue #193).

  It only adds. Every plaintext column keeps its name, its type, and its rows;
  what it loses is `NOT NULL`, because the release that follows writes the
  ciphertext and leaves the plaintext empty. Retyping a live column here would
  break every node still running the previous release for as long as a rolling
  replacement takes, which is the failure `RELEASE-006` exists around, so the
  plaintext columns are dropped by a contract migration a release later rather
  than by this one.

  The `_present` constraints are what keep "this row has text" true across the
  transition: an un-replaced node writes the plaintext column, a replaced one
  writes the ciphertext column, and neither can write a row with neither.
  `voice_sessions.compaction_summary` gets no such constraint because it is
  optional by design — `OpenAgents.Voice.Retention` nulls it on purge.

  `preference_observation_shape` is left alone deliberately. It bounds
  `octet_length(summary)`, and a `CHECK` is satisfied unless it evaluates to
  false, so a null summary leaves that conjunct null and the constraint
  passes — the same reason `voice_transcript_items_content_bounded` needs no
  edit either.
  """

  use Ecto.Migration

  # {table, plaintext column, ciphertext column, ciphertext upper bound, present check?}
  @columns [
    {:voice_transcript_items, :content, :content_ciphertext, 16_064, true},
    {:voice_sessions, :compaction_summary, :compaction_summary_ciphertext, 8_256, false},
    {:preference_observations, :summary, :summary_ciphertext, 576, true},
    {:project_notes, :body, :body_ciphertext, 131_136, true}
  ]

  def up do
    for {table, plaintext, ciphertext, bound, present?} <- @columns do
      alter table(table) do
        add ciphertext, :binary
      end

      # `compaction_summary` is already nullable, and only the columns that
      # carry a present-check ever had `NOT NULL` to drop.
      if present?, do: execute("ALTER TABLE #{table} ALTER COLUMN #{plaintext} DROP NOT NULL")

      create constraint(table, :"#{table}_#{ciphertext}_bounded",
               check:
                 "#{ciphertext} IS NULL OR octet_length(#{ciphertext}) BETWEEN 30 AND #{bound}"
             )

      if present? do
        create constraint(table, :"#{table}_#{plaintext}_present",
                 check: "#{plaintext} IS NOT NULL OR #{ciphertext} IS NOT NULL"
               )
      end
    end
  end

  def down do
    for {table, plaintext, ciphertext, _bound, present?} <- @columns do
      if present?, do: drop(constraint(table, :"#{table}_#{plaintext}_present"))

      drop constraint(table, :"#{table}_#{ciphertext}_bounded")

      if present?, do: execute("ALTER TABLE #{table} ALTER COLUMN #{plaintext} SET NOT NULL")

      alter table(table) do
        remove ciphertext
      end
    end
  end
end
