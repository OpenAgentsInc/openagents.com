defmodule OpenAgents.Repo.Migrations.CreateIssueNotifications do
  use Ecto.Migration

  def change do
    # Who follows an issue, and why. `subscribed` is a three-state answer
    # collapsed into a row plus a boolean: no row means "never took part",
    # `true` means "follows", and `false` means "took part and then muted".
    # Muting has to be a row rather than a deletion, because participating
    # again would otherwise resubscribe someone who already said no.
    create table(:issue_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :reason, :string, null: false
      add :subscribed, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:issue_subscriptions, [:issue_id, :user_id])
    create index(:issue_subscriptions, [:user_id])
    create index(:issue_subscriptions, [:repository_id])

    create constraint(:issue_subscriptions, :issue_subscriptions_reason_check,
             check: "reason in ('author', 'commented', 'mentioned', 'manual')"
           )

    # A notification is a pointer, never a copy. It names the repository, the
    # issue, the comment, and the actor's login, and it stores no title and no
    # body. Reading joins back through `Repositories.readable_by/2`, so a
    # recipient who loses membership stops seeing the row instead of keeping a
    # rendered snapshot of a private issue in their inbox.
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :comment_id, references(:comments, on_delete: :delete_all)
      add :kind, :string, null: false
      add :actor_login, :string

      # The idempotency key. One event produces one string per recipient, so a
      # retried fan-out collides with the row it already wrote instead of
      # notifying twice. It is a column rather than a composite index over
      # nullable `comment_id`, because a partial index would need one variant
      # per event shape and would grow with every new shape.
      add :dedupe_key, :string, null: false

      add :read_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:notifications, [:user_id, :dedupe_key])

    # The inbox reads one recipient's rows newest first, and the unread count
    # reads the same rows filtered by `read_at`.
    create index(:notifications, [:user_id, :inserted_at])
    create index(:notifications, [:user_id, :read_at])
    create index(:notifications, [:issue_id])
    create index(:notifications, [:repository_id])

    create constraint(:notifications, :notifications_kind_check,
             check: "kind in ('mention', 'issue_comment')"
           )

    # Preference controls. A missing row means every category is on, so the
    # defaults live in one place rather than being written into every account
    # at signup and drifting from the schema afterwards.
    create table(:notification_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :mentions_enabled, :boolean, null: false, default: true
      add :issue_comments_enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:notification_preferences, [:user_id])
  end
end
