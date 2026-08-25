defmodule OpenAgents.Notifications.EmailChannelTest do
  @moduledoc """
  Proofs for the gate an address has to pass before anything is sent to it.

  The claim under test is narrow and absolute: `verified_address/1` is the only
  read any send resolves its recipient through, and it returns `nil` for every
  address a code has not come back from. The database says the same thing
  independently, so the last test here goes around this module entirely and
  asks PostgreSQL.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures
  import Swoosh.TestAssertions

  alias OpenAgents.Accounts.User
  alias OpenAgents.Notifications.EmailChannel

  setup do
    %{user: repository_user_fixture("addressee-#{System.unique_integer([:positive])}")}
  end

  describe "recording an address" do
    test "stores it unverified, and an unverified address is not a recipient", %{user: user} do
      assert {:ok, updated} = EmailChannel.set_address(user, "Someone@Example.com")

      assert updated.notification_email == "someone@example.com"
      assert is_nil(updated.notification_email_verified_at)
      assert EmailChannel.verified_address(updated) == nil

      assert EmailChannel.state(updated) == %{
               address: "someone@example.com",
               verified?: false,
               pending?: true
             }
    end

    test "mails the code to the address, and holds only its digest", %{user: user} do
      assert {:ok, updated} = EmailChannel.set_address(user, "someone@example.com")

      assert_email_sent(fn email ->
        assert email.to == [{"", "someone@example.com"}]
        assert [code] = Regex.run(~r/[0-9A-Z]{8}/, email.subject)
        assert email.text_body =~ code
        assert updated.notification_email_code_digest == :crypto.hash(:sha256, code)
      end)
    end

    test "refuses an address that is not one", %{user: user} do
      for bad <- ["", "someone", "someone@example", "two@parts@example.com", "a b@example.com"] do
        assert EmailChannel.set_address(user, bad) == {:error, :invalid_address}
      end

      assert_no_email_sent()
    end

    test "refuses to collect an address at all where nothing can be sent", %{user: user} do
      configured = Application.get_env(:openagents, EmailChannel)
      Application.put_env(:openagents, EmailChannel, Keyword.put(configured, :deliverable, false))
      on_exit(fn -> Application.put_env(:openagents, EmailChannel, configured) end)

      refute EmailChannel.deliverable?()
      assert EmailChannel.set_address(user, "someone@example.com") == {:error, :not_deliverable}
      assert_no_email_sent()
    end
  end

  describe "confirming an address" do
    setup %{user: user} do
      {:ok, pending} = EmailChannel.set_address(user, "someone@example.com")
      %{pending: pending, code: sent_code()}
    end

    test "the right code makes it a recipient", %{pending: pending, code: code} do
      assert {:ok, verified} = EmailChannel.verify(pending, code)

      assert EmailChannel.verified_address(verified) == "someone@example.com"
      assert verified.notification_email_verified_at != nil
      assert EmailChannel.state(verified).verified?
    end

    test "the code is spent, so the same one cannot be replayed", %{pending: pending, code: code} do
      assert {:ok, verified} = EmailChannel.verify(pending, code)
      assert EmailChannel.verify(verified, code) == {:error, :nothing_pending}
    end

    test "case and surrounding space do not matter", %{pending: pending, code: code} do
      assert {:ok, verified} = EmailChannel.verify(pending, "  #{String.downcase(code)} ")
      assert EmailChannel.verified_address(verified) == "someone@example.com"
    end

    test "a wrong code is counted, and the fifth retires the code", %{pending: pending} do
      user =
        Enum.reduce(1..4, pending, fn attempt, current ->
          assert EmailChannel.verify(current, "00000000") == {:error, :incorrect_code}
          reloaded = Repo.get!(User, current.id)
          assert reloaded.notification_email_code_attempts == attempt
          reloaded
        end)

      assert EmailChannel.verify(user, "00000000") == {:error, :too_many_attempts}

      spent = Repo.get!(User, user.id)
      assert is_nil(spent.notification_email_code_digest)
      assert EmailChannel.verified_address(spent) == nil
    end

    test "an expired code is refused, and the address stays unverified", %{
      pending: pending,
      code: code
    } do
      stale =
        pending
        |> Ecto.Changeset.change(
          notification_email_code_sent_at: DateTime.add(DateTime.utc_now(), -1_801, :second)
        )
        |> Repo.update!()

      assert EmailChannel.verify(stale, code) == {:error, :expired}
      assert EmailChannel.verified_address(Repo.get!(User, stale.id)) == nil
    end

    test "another code cannot be asked for within the minute", %{pending: pending} do
      assert EmailChannel.resend_code(pending) == {:error, :too_soon}
    end

    test "a fresh code retires the old one and resets the guesses", %{
      pending: pending,
      code: code
    } do
      assert {:error, :incorrect_code} = EmailChannel.verify(pending, "00000000")

      guessed =
        User
        |> Repo.get!(pending.id)
        |> Ecto.Changeset.change(
          notification_email_code_sent_at: DateTime.add(DateTime.utc_now(), -120, :second)
        )
        |> Repo.update!()

      assert {:ok, reissued} = EmailChannel.resend_code(guessed)
      reissued_code = sent_code()

      assert reissued.notification_email_code_attempts == 0
      assert EmailChannel.verify(reissued, code) == {:error, :incorrect_code}

      assert {:ok, verified} = EmailChannel.verify(Repo.get!(User, pending.id), reissued_code)
      assert EmailChannel.verified_address(verified) == "someone@example.com"
    end
  end

  describe "changing and removing an address" do
    setup %{user: user} do
      {:ok, pending} = EmailChannel.set_address(user, "first@example.com")
      {:ok, verified} = EmailChannel.verify(pending, sent_code())
      %{verified: verified}
    end

    test "a new address is not a recipient until it is confirmed too", %{verified: verified} do
      assert {:ok, changed} = EmailChannel.set_address(verified, "second@example.com")

      assert changed.notification_email == "second@example.com"
      assert EmailChannel.verified_address(changed) == nil

      assert {:ok, reverified} = EmailChannel.verify(changed, sent_code())
      assert EmailChannel.verified_address(reverified) == "second@example.com"
    end

    test "retyping the confirmed address is not a withdrawal of the proof", %{verified: verified} do
      assert {:ok, unchanged} = EmailChannel.set_address(verified, "FIRST@example.com")

      assert EmailChannel.verified_address(unchanged) == "first@example.com"
      assert_no_email_sent()
    end

    test "removal takes the address, the proof, and any outstanding code", %{verified: verified} do
      assert {:ok, removed} = EmailChannel.remove_address(verified)

      assert is_nil(removed.notification_email)
      assert is_nil(removed.notification_email_verified_at)
      assert is_nil(removed.notification_email_code_digest)
      assert EmailChannel.verified_address(removed) == nil
      assert EmailChannel.resend_code(removed) == {:error, :nothing_pending}
    end
  end

  describe "the database's own half of the gate" do
    test "a verified timestamp cannot stand on a row that names no address", %{user: user} do
      changeset =
        Ecto.Changeset.change(user, notification_email_verified_at: DateTime.utc_now())

      assert_raise Ecto.ConstraintError, ~r/users_notification_email_state_check/, fn ->
        Repo.update(changeset)
      end
    end
  end

  # The code exists in exactly one place a test may read it: the message that
  # was sent. Reading it from the row would prove nothing, because the row holds
  # a digest.
  defp sent_code do
    assert_receive {:email, %Swoosh.Email{subject: subject}}
    hd(Regex.run(~r/[0-9A-Z]{8}/, subject))
  end
end
