defmodule OpenAgents.Repo.Migrations.AddNotificationEmailAddressToUsers do
  @moduledoc """
  An address to send to, and the proof that its owner asked for it.

  GitHub OAuth is not asked for `user:email` here. The address is typed into
  the notification settings by the person who wants mail, and it is inert until
  a code sent to that mailbox comes back. So the account carries four facts:
  the address, when it was verified, the digest of the code currently
  outstanding, and when that code went out.

  The code is stored as a SHA-256 digest, never as plaintext, for the same
  reason a token is: a database read must not be enough to claim somebody
  else's mailbox. `notification_email_code_attempts` bounds guessing at the
  address, since a short code is guessable if the guesses are free.

  The check constraint is the durable half of the gate. `verified_at` cannot be
  set without an address, and a code cannot be outstanding without one either,
  so no row can claim a verified mailbox it does not name. The application
  refuses first; this refuses when the application is wrong.

  Expand-only: every column is nullable or defaulted, so a node running the
  previous release keeps writing rows this migration accepts.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :notification_email, :text
      add :notification_email_verified_at, :utc_datetime_usec
      add :notification_email_code_digest, :binary
      add :notification_email_code_sent_at, :utc_datetime_usec
      add :notification_email_code_attempts, :integer, null: false, default: 0
    end

    create constraint(:users, :users_notification_email_state_check,
             check: """
             notification_email IS NOT NULL
               OR (notification_email_verified_at IS NULL
                   AND notification_email_code_digest IS NULL
                   AND notification_email_code_sent_at IS NULL)
             """
           )
  end
end
