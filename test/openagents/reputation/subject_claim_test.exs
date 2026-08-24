defmodule OpenAgents.Reputation.SubjectClaimTest do
  @moduledoc """
  The binding that resolves an attestation subject to an account, #171.

  A changeset is the application's opinion. What decides here is the table, so
  every rule this file cares about is asserted against the constraint itself —
  by reading `pg_get_constraintdef` and by inserting through raw SQL, which no
  changeset sees. A rule that only a changeset enforced would leave the bare
  string exactly as ambiguous as it was.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Agents.{Agent, AgentUserLink}
  alias OpenAgents.Forum.ActorLink
  alias OpenAgents.Repo
  alias OpenAgents.Reputation
  alias OpenAgents.Reputation.SubjectClaim

  describe "what the table decides" do
    test "the per-kind reference constraint is the database's rule, stated in SQL" do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
          ["reputation_subject_claims_reference_check"]
        )

      # An account subject names the account itself, and the string is
      # checkable without an operator. The other two kinds must carry the row
      # in the namespace that established them.
      assert definition =~ "'user:'"
      assert definition =~ "forum_actor_link_id IS NOT NULL"
      assert definition =~ "agent_id IS NOT NULL"
    end

    test "an account subject that is not this account's actor reference is refused in SQL" do
      user = user_fixture()

      assert_raise Postgrex.Error, ~r/reputation_subject_claims_reference_check/, fn ->
        insert_claim!(%{
          subject_kind: "account",
          subject_id: "user:" <> Ecto.UUID.generate(),
          user_id: user.id
        })
      end
    end

    test "a forum_actor subject with no link row is refused in SQL" do
      user = user_fixture()

      assert_raise Postgrex.Error, ~r/reputation_subject_claims_reference_check/, fn ->
        insert_claim!(%{
          subject_kind: "forum_actor",
          subject_id: "agent:user_legacy",
          user_id: user.id
        })
      end
    end

    test "an agent subject carrying a forum link instead of an agent is refused in SQL" do
      user = user_fixture()
      link = linked_actor_link(user, "agent:user_mixed")

      assert_raise Postgrex.Error, ~r/reputation_subject_claims_reference_check/, fn ->
        insert_claim!(%{
          subject_kind: "agent",
          subject_id: "agent:user_mixed",
          user_id: user.id,
          forum_actor_link_id: link.id
        })
      end
    end

    test "a subject one account holds cannot be claimed by another, in SQL" do
      first = user_fixture()
      second = user_fixture()

      {:ok, _claim} =
        Reputation.claim_subject(first, %{
          subject_kind: "account",
          subject_id: "user:" <> first.id
        })

      # The unique index is on `subject_id` alone rather than on the kind and
      # the string together: an attestation names its subject with the bare
      # string, so two kinds carrying one string would put the ambiguity back.
      assert_raise Postgrex.Error, ~r/reputation_subject_claims_subject_id_index/, fn ->
        insert_claim!(%{
          subject_kind: "forum_actor",
          subject_id: "user:" <> first.id,
          user_id: second.id,
          forum_actor_link_id: linked_actor_link(second, "user:" <> first.id).id
        })
      end
    end
  end

  describe "what the context decides, because a constraint cannot read another table" do
    test "a forum_actor claim needs a linked forum_actor_links row of this account's" do
      user = user_fixture()
      other = user_fixture()

      assert {:error, :forum_actor_not_linked} =
               Reputation.claim_subject(user, %{
                 subject_kind: "forum_actor",
                 subject_id: "agent:user_absent",
                 forum_actor_link_id: Ecto.UUID.generate()
               })

      theirs = linked_actor_link(other, "agent:user_theirs")

      assert {:error, :forum_actor_not_linked} =
               Reputation.claim_subject(user, %{
                 subject_kind: "forum_actor",
                 subject_id: "agent:user_theirs",
                 forum_actor_link_id: theirs.id
               })

      pending =
        Repo.insert!(%ActorLink{
          user_id: user.id,
          actor_ref: "agent:user_pending",
          status: "pending"
        })

      assert {:error, :forum_actor_not_linked} =
               Reputation.claim_subject(user, %{
                 subject_kind: "forum_actor",
                 subject_id: "agent:user_pending",
                 forum_actor_link_id: pending.id
               })

      mine = linked_actor_link(user, "agent:user_mine")

      assert {:error, :subject_is_not_the_actor_ref} =
               Reputation.claim_subject(user, %{
                 subject_kind: "forum_actor",
                 subject_id: "agent:user_something_else",
                 forum_actor_link_id: mine.id
               })

      assert {:ok, claim} =
               Reputation.claim_subject(user, %{
                 subject_kind: "forum_actor",
                 subject_id: "agent:user_mine",
                 forum_actor_link_id: mine.id
               })

      assert claim.status == "pending"
    end

    test "an agent claim needs a linked agent_user_links row of this account's" do
      user = user_fixture()
      agent = agent_fixture("subject-claim-agent")

      assert {:error, :agent_not_linked} =
               Reputation.claim_subject(user, %{
                 subject_kind: "agent",
                 subject_id: "agent:" <> agent.handle,
                 agent_id: agent.id
               })

      Repo.insert!(%AgentUserLink{agent_id: agent.id, user_id: user.id, status: "linked"})

      assert {:ok, claim} =
               Reputation.claim_subject(user, %{
                 subject_kind: "agent",
                 subject_id: "agent:" <> agent.handle,
                 agent_id: agent.id
               })

      assert claim.subject_kind == "agent"
    end
  end

  describe "only a decided claim resolves" do
    test "a pending or rejected claim resolves nothing, and a linked one resolves one string" do
      user = user_fixture()

      {:ok, claim} =
        Reputation.claim_subject(user, %{
          subject_kind: "account",
          subject_id: "user:" <> user.id
        })

      assert Reputation.linked_subject_ids(user) == []

      {:ok, linked} = Reputation.approve_subject_claim(claim)
      assert linked.status == "linked"
      assert Reputation.linked_subject_ids(user) == ["user:" <> user.id]

      assert {:error, :not_pending} = Reputation.approve_subject_claim(linked)
      assert {:error, :not_pending} = Reputation.reject_subject_claim(linked)
    end

    test "a rejected claim never resolves" do
      user = user_fixture()

      {:ok, claim} =
        Reputation.claim_subject(user, %{
          subject_kind: "account",
          subject_id: "user:" <> user.id
        })

      {:ok, rejected} = Reputation.reject_subject_claim(claim)
      assert rejected.status == "rejected"
      assert Reputation.linked_subject_ids(user) == []
    end
  end

  ## helpers

  defp user_fixture do
    OpenAgents.AccountsFixtures.repository_user_fixture(
      "subject-claim-#{System.unique_integer([:positive])}"
    )
  end

  defp agent_fixture(prefix) do
    Repo.insert!(%Agent{
      handle: "#{prefix}-#{System.unique_integer([:positive])}",
      display_name: "Subject claim agent",
      registration_ip_digest: :crypto.hash(:sha256, prefix)
    })
  end

  defp linked_actor_link(user, actor_ref) do
    Repo.insert!(%ActorLink{
      user_id: user.id,
      actor_ref: actor_ref,
      status: "linked",
      linked_at: DateTime.utc_now()
    })
  end

  # Straight past every changeset, so what refuses the row is the table.
  defp insert_claim!(attributes) do
    now = DateTime.utc_now()

    Repo.insert_all(SubjectClaim, [
      attributes
      |> Map.put_new(:status, "pending")
      |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})
    ])
  end
end
