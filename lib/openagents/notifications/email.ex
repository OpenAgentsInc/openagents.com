defmodule OpenAgents.Notifications.Email do
  @moduledoc """
  The two messages this application sends, and the mailer it sends them with.

  Both are plain text. A notification is a pointer with a link on it, which
  needs no layout, and a text part renders in every client without a fallback
  to maintain.

  ## What a notification message may say

  `NOTIFY-001` says a notification record stores identifiers, a kind, and the
  actor's login, never a title or a body. The message obeys the same rule for
  the same reason: it leaves the application, so it is the one copy of a
  notification that no later authorization check can withdraw. The repository
  path and the issue number travel because a link is useless without them and
  because the recipient's access to that repository was rechecked on the way
  out. The issue's title did not travel, and does not.

  ## Where they are sent from

  One `from` for both, configured under
  `OpenAgents.Notifications.EmailChannel`, so a deployment sets its sending
  identity in one place and no call site invents one.
  """

  import Swoosh.Email

  alias OpenAgents.Mailer
  alias OpenAgents.Notifications.EmailChannel

  @doc """
  Mails a verification code to an address nobody has confirmed yet.

  This is the one message that goes to an unverified address, and it is what
  makes verification possible at all. It carries the code and nothing about the
  account: an address typed by mistake learns that somebody asked, not who.
  """
  @spec deliver_verification(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_verification(address, code) when is_binary(address) and is_binary(code) do
    new()
    |> to(address)
    |> from(EmailChannel.from())
    |> subject("Your OpenAgents verification code: #{code}")
    |> text_body("""
    Somebody asked to send OpenAgents notifications to this address.

    Your verification code is:

        #{code}

    Enter it on the notifications page to confirm the address. The code is good
    for 30 minutes.

    If this was not you, ignore this message. Nothing is sent to an address that
    has not been confirmed, so no further mail will arrive.
    """)
    |> Mailer.deliver()
  end

  @doc """
  Mails one notification to a confirmed address.

  `pointer` is what `OpenAgents.Notifications.email_dispatch/1` resolved: the
  kind, the actor's login, the repository path, the issue number, and the URL.
  Nothing else reaches this function, so nothing else can reach the message.
  """
  @spec deliver_notification(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def deliver_notification(address, pointer) when is_binary(address) and is_map(pointer) do
    reference = "#{pointer["repository"]}##{pointer["issue_number"]}"

    new()
    |> to(address)
    |> from(EmailChannel.from())
    |> subject("#{headline(pointer)} on #{reference}")
    |> text_body("""
    #{headline(pointer)} on #{reference}.

    #{pointer["url"]}

    You are receiving this because email delivery is on for your account. Turn
    it off, or change the address, on the notifications page:

    #{pointer["settings_url"]}
    """)
    |> Mailer.deliver()
  end

  defp headline(%{"kind" => "mention", "actor_login" => login}) when is_binary(login),
    do: "#{login} mentioned you"

  defp headline(%{"kind" => "mention"}), do: "You were mentioned"
  defp headline(_pointer), do: "There is activity"
end
