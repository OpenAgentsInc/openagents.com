defmodule OpenAgents.Repo.Migrations.NotifyOnIssueEvents do
  use Ecto.Migration

  def up do
    # Five more kinds, derived from the difference between an issue before and
    # after an update rather than read out of an event log. There is no
    # `issue_events` table yet; when one lands, the derivation moves to it and
    # these kinds stay.
    drop constraint(:notifications, :notifications_kind_check)

    create constraint(:notifications, :notifications_kind_check,
             check: """
             kind in (
               'mention', 'issue_comment', 'assigned', 'unassigned',
               'labeled', 'unlabeled', 'state_changed'
             )
             """
           )

    # Being handed an issue is its own reason to follow it, distinct from
    # opening it, commenting on it, or being named in it.
    drop constraint(:issue_subscriptions, :issue_subscriptions_reason_check)

    create constraint(:issue_subscriptions, :issue_subscriptions_reason_check,
             check: "reason in ('author', 'commented', 'mentioned', 'assigned', 'manual')"
           )

    # Three categories rather than one, because a category has to name what it
    # delivers for turning it off to have a predictable effect. Assignment is
    # addressed to one person and defaults on. Issue activity — closed and
    # reopened — reaches the people already following and defaults on. Label
    # changes are the noisy one, addressed to nobody in particular, so they
    # default off and stay off until somebody asks for them.
    alter table(:notification_preferences) do
      add :assignments_enabled, :boolean, null: false, default: true
      add :issue_activity_enabled, :boolean, null: false, default: true
      add :label_changes_enabled, :boolean, null: false, default: false
    end
  end

  def down do
    execute "update issue_subscriptions set reason = 'manual' where reason = 'assigned'"

    drop constraint(:issue_subscriptions, :issue_subscriptions_reason_check)

    create constraint(:issue_subscriptions, :issue_subscriptions_reason_check,
             check: "reason in ('author', 'commented', 'mentioned', 'manual')"
           )

    alter table(:notification_preferences) do
      remove :assignments_enabled
      remove :issue_activity_enabled
      remove :label_changes_enabled
    end

    # Rows carrying a kind this constraint no longer admits have to go before
    # it can be restored, or the constraint cannot be validated.
    execute """
    delete from notifications
    where kind not in ('mention', 'issue_comment')
    """

    drop constraint(:notifications, :notifications_kind_check)

    create constraint(:notifications, :notifications_kind_check,
             check: "kind in ('mention', 'issue_comment')"
           )
  end
end
