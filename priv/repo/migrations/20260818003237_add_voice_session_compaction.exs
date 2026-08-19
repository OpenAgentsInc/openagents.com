defmodule Sarah.Repo.Migrations.AddVoiceSessionCompaction do
  use Ecto.Migration

  # In-call context compaction (issue #68): the latest bounded progress summary
  # Sarah produced before the runtime pruned old provider items, plus how many
  # summaries this generation persisted. The summary is continuity evidence for
  # a long call, never a replacement for voice_transcript_items/messages
  # authority, and it is scrubbed by the operational retention sweep.
  def change do
    alter table(:voice_sessions) do
      add :compaction_summary, :text
      add :compaction_count, :integer, null: false, default: 0
    end

    create constraint(:voice_sessions, :voice_sessions_compaction_count_nonnegative,
             check: "compaction_count >= 0"
           )
  end
end
