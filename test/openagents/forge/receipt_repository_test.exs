defmodule OpenAgents.Forge.ReceiptRepositoryTest do
  @moduledoc """
  Which repository a build or deploy receipt belongs to, #181.

  `forge_builds.repo` and `forge_deploys.repo` hold a repository *name*, and
  `repositories` is unique on `{namespace_id, name_key}` rather than on `name`,
  so a name can answer for two repositories. This file pins what the string
  could not decide and what the key now does.
  """

  use OpenAgents.DataCase, async: false

  import Ecto.Query

  alias OpenAgents.AccountsFixtures
  alias OpenAgents.Forge.{BuildReceipt, DeployReceipt, ReceiptRepository}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository

  describe "what each receipt column actually holds" do
    test "a push receipt's repo is a storage key, which is already unambiguous" do
      # `forge_pushes` deliberately has no `repository_id`. This is the reason:
      # its `repo` is `Repository.storage_key`, which carries a unique index,
      # so it names exactly one repository already. EXIT-003 keeps every column
      # there re-derivable from the WAL, and a key only PostgreSQL can produce
      # would make the database a second opinion about a push.
      %{rows: [[unique?]]} =
        Repo.query!("""
        SELECT count(*) = 1
        FROM pg_indexes
        WHERE tablename = 'repositories'
          AND indexdef LIKE 'CREATE UNIQUE INDEX%(storage_key)'
        """)

      assert unique?

      refute :repository_id in OpenAgents.Forge.PushReceipt.__schema__(:fields)

      %{rows: [[present]]} =
        Repo.query!("""
        SELECT count(*) FROM information_schema.columns
        WHERE table_name = 'forge_pushes' AND column_name = 'repository_id'
        """)

      assert present == 0
    end

    test "a build or deploy receipt's repo is a name, which two repositories can share" do
      first = AccountsFixtures.repository_fixture(%{owner: "FirstOrg", name: "shared-name"})
      second = AccountsFixtures.repository_fixture(%{owner: "SecondOrg", name: "shared-name"})

      assert first.name == second.name
      refute first.storage_key == second.storage_key

      assert Repo.aggregate(from(r in Repository, where: r.name == "shared-name"), :count) == 2
    end
  end

  describe "resolve/1" do
    test "answers for a storage key, a bare name, and an owner/name path" do
      repository = AccountsFixtures.repository_fixture(%{owner: "ResolveOrg", name: "resolvable"})

      assert ReceiptRepository.resolve(repository.storage_key).id == repository.id
      assert ReceiptRepository.resolve("resolvable").id == repository.id
      assert ReceiptRepository.resolve("ResolveOrg/resolvable").id == repository.id
    end

    test "refuses a name two repositories answer to, and a name none answers to" do
      AccountsFixtures.repository_fixture(%{owner: "AmbiguousA", name: "two-answers"})
      AccountsFixtures.repository_fixture(%{owner: "AmbiguousB", name: "two-answers"})

      assert ReceiptRepository.resolve("two-answers") == nil
      assert ReceiptRepository.resolve("no-such-repository") == nil
      assert ReceiptRepository.resolve(nil) == nil
    end
  end

  describe "scope/3" do
    test "a keyed receipt is matched by its key and never by another repository's name" do
      mine = AccountsFixtures.repository_fixture(%{owner: "ScopeMine", name: "collide"})
      theirs = AccountsFixtures.repository_fixture(%{owner: "ScopeTheirs", name: "collide"})

      ours = build_receipt!("collide", mine.id)
      not_ours = build_receipt!("collide", theirs.id)

      found =
        BuildReceipt
        |> ReceiptRepository.scope(mine, ["collide"])
        |> select([b], b.id)
        |> Repo.all()

      assert ours.id in found
      refute not_ours.id in found
    end

    test "a receipt with no key still reads by its string" do
      repository = AccountsFixtures.repository_fixture(%{owner: "ScopeOld", name: "historical"})
      unkeyed = build_receipt!("historical", nil)

      found =
        BuildReceipt
        |> ReceiptRepository.scope(repository, ["historical"])
        |> select([b], b.id)
        |> Repo.all()

      assert unkeyed.id in found
    end

    test "with no repository to name, the string is all there is" do
      unkeyed = build_receipt!("unsettled-name", nil)

      found =
        BuildReceipt
        |> ReceiptRepository.scope(nil, ["unsettled-name"])
        |> select([b], b.id)
        |> Repo.all()

      assert found == [unkeyed.id]
    end
  end

  describe "backfill!/1" do
    test "fills a name exactly one repository answers to and leaves the rest null" do
      repository = AccountsFixtures.repository_fixture(%{owner: "FillOrg", name: "fillable"})
      AccountsFixtures.repository_fixture(%{owner: "ClashA", name: "clashing"})
      AccountsFixtures.repository_fixture(%{owner: "ClashB", name: "clashing"})

      by_name = build_receipt!("fillable", nil)
      by_path = build_receipt!("FillOrg/fillable", nil)
      by_storage_key = build_receipt!(repository.storage_key, nil)
      ambiguous = build_receipt!("clashing", nil)
      absent = build_receipt!("gone-from-the-forge", nil)

      assert ReceiptRepository.backfill!("forge_builds") >= 3

      assert reload(by_name).repository_id == repository.id
      assert reload(by_path).repository_id == repository.id
      assert reload(by_storage_key).repository_id == repository.id

      # A backfill that guesses is worse than a null. Both of these stay null,
      # and a null means "not settled", never "no repository".
      assert reload(ambiguous).repository_id == nil
      assert reload(absent).repository_id == nil
    end

    test "it is idempotent and never re-points a receipt that already names one" do
      first = AccountsFixtures.repository_fixture(%{owner: "IdemA", name: "idempotent"})
      second = AccountsFixtures.repository_fixture(%{owner: "IdemB", name: "elsewhere"})

      # Deliberately pointed at the repository its name does not name.
      receipt = build_receipt!("idempotent", second.id)

      assert ReceiptRepository.backfill!("forge_builds") >= 0
      assert reload(receipt).repository_id == second.id
      refute reload(receipt).repository_id == first.id
    end

    test "it does not carry the authority to rewrite a deploy receipt" do
      repository = AccountsFixtures.repository_fixture(%{owner: "TriggerOrg", name: "triggered"})
      receipt = deploy_receipt!("triggered", nil)

      # `forge_deploys` refuses every UPDATE. The migration suspends the trigger
      # for the length of its own transaction; `backfill!/1` does not, so a
      # caller cannot quietly acquire that authority.
      assert_raise Postgrex.Error, ~r/forge deployment receipts are immutable/, fn ->
        ReceiptRepository.backfill!("forge_deploys")
      end

      Repo.query!("ALTER TABLE forge_deploys DISABLE TRIGGER forge_deploy_receipts_immutable")
      assert ReceiptRepository.backfill!("forge_deploys") >= 1
      Repo.query!("ALTER TABLE forge_deploys ENABLE TRIGGER forge_deploy_receipts_immutable")

      assert Repo.get(DeployReceipt, receipt.id).repository_id == repository.id
    end
  end

  ## helpers

  defp build_receipt!(repo, repository_id) do
    %BuildReceipt{}
    |> BuildReceipt.changeset(%{
      repo: repo,
      repository_id: repository_id,
      sha: String.duplicate("a", 40),
      target_id: Ecto.UUID.generate(),
      status: "complete"
    })
    |> Repo.insert!()
  end

  defp deploy_receipt!(repo, repository_id) do
    %DeployReceipt{}
    |> DeployReceipt.changeset(%{
      repo: repo,
      repository_id: repository_id,
      sha: String.duplicate("b", 40),
      target_id: Ecto.UUID.generate(),
      result: "live"
    })
    |> Repo.insert!()
  end

  defp reload(%BuildReceipt{id: id}), do: Repo.get!(BuildReceipt, id)
end
