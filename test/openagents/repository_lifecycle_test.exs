defmodule OpenAgents.RepositoryLifecycleTest do
  use OpenAgents.DataCase

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.{Namespace, NamespaceAlias, ProvisioningOutbox, RepositoryImport}

  test "projects a GitHub user namespace by numeric account ID and retains a renamed slug alias" do
    user = repository_user_fixture("before-rename")

    assert {:ok, namespace} = Repositories.ensure_user_namespace(user)
    assert namespace.provider == "github"
    assert namespace.provider_account_id == user.github_id
    assert namespace.slug == "before-rename"
    assert namespace.kind == "user"
    assert namespace.owner_user_id == user.id

    assert {:ok, renamed} =
             Repositories.upsert_github_namespace(%{
               provider_account_id: user.github_id,
               slug: "after-rename",
               kind: "user",
               owner_user_id: user.id
             })

    assert renamed.id == namespace.id
    assert renamed.slug == "after-rename"
    assert Repositories.get_namespace_by_slug!("after-rename").id == namespace.id
    assert Repositories.get_namespace_by_slug!("before-rename").id == namespace.id

    assert Repo.get_by!(NamespaceAlias,
             namespace_id: namespace.id,
             slug_key: "before-rename"
           )
  end

  test "creates a ready-to-provision repository, owner membership, and outbox atomically" do
    user = repository_user_fixture("repo-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(
               user,
               %{
                 name: "new-project",
                 description: "Created through the public repository contract",
                 visibility: "private",
                 default_branch: "main"
               },
               "create-key-1"
             )

    assert repository.owner == user.github_login
    assert repository.namespace.provider_account_id == user.github_id
    assert repository.lifecycle_state == "provisioning"
    assert repository.provisioning_kind == "empty"
    assert is_binary(repository.storage_key)
    assert Repositories.writable?(repository, user)

    repository_id = repository.id

    assert %ProvisioningOutbox{
             repository_id: ^repository_id,
             operation: "create",
             state: "pending"
           } = Repo.get_by!(ProvisioningOutbox, repository_id: repository.id)
  end

  test "replays the same idempotent create and rejects a different request" do
    user = repository_user_fixture("idempotent-owner")
    attrs = %{name: "same-project", visibility: "private", default_branch: "main"}

    assert {:ok, first, :created} =
             Repositories.create_user_repository(user, attrs, "create-key-2")

    assert {:ok, replayed, :replayed} =
             Repositories.create_user_repository(user, attrs, "create-key-2")

    assert replayed.id == first.id

    assert {:error, :idempotency_conflict} =
             Repositories.create_user_repository(
               user,
               %{attrs | name: "different-project"},
               "create-key-2"
             )
  end

  test "records a one-time GitHub import without a credential" do
    user = repository_user_fixture("import-owner")

    source = %{
      provider: "github",
      source_repository_id: 4_242,
      source_owner_id: user.github_id,
      source_full_name: "import-owner/source-project",
      source_default_branch: "main",
      source_ref_digest: String.duplicate("a", 64),
      source_head_sha: String.duplicate("b", 40),
      source_refs: %{
        "refs/heads/main" => String.duplicate("b", 40),
        "refs/tags/v1" => String.duplicate("c", 40)
      }
    }

    assert {:ok, repository, repository_import, :created} =
             Repositories.create_user_import(
               user,
               source,
               %{name: "source-project", visibility: "private"},
               "import-key-1"
             )

    assert repository.provisioning_kind == "github_import"
    assert repository_import.repository_id == repository.id
    assert repository_import.source_repository_id == 4_242
    assert repository_import.source_owner_id == user.github_id
    assert repository_import.source_ref_digest == String.duplicate("a", 64)
    assert repository_import.source_refs == source.source_refs
    assert repository_import.state == "pending"

    fields = RepositoryImport.__schema__(:fields)
    refute :token in fields
    refute :clone_url in fields
    refute :credential in fields

    assert %ProvisioningOutbox{operation: "github_import"} =
             Repo.get_by!(ProvisioningOutbox, repository_id: repository.id)
  end

  test "lists only repositories visible to the active user" do
    owner = repository_user_fixture("list-owner")
    viewer = repository_user_fixture("list-viewer")
    outsider = repository_user_fixture("list-outsider")

    assert {:ok, public_repository, :created} =
             Repositories.create_user_repository(
               owner,
               %{name: "public-project", visibility: "public"},
               "public-key"
             )

    assert {:ok, private_repository, :created} =
             Repositories.create_user_repository(
               owner,
               %{name: "private-project", visibility: "private"},
               "private-key"
             )

    assert {:ok, _membership} = Repositories.add_member(private_repository, viewer, "viewer")

    viewer_repository_ids = Enum.map(Repositories.list_visible_repositories(viewer), & &1.id)
    outsider_repository_ids = Enum.map(Repositories.list_visible_repositories(outsider), & &1.id)

    assert public_repository.id in viewer_repository_ids
    assert private_repository.id in viewer_repository_ids
    assert public_repository.id in outsider_repository_ids
    refute private_repository.id in outsider_repository_ids
  end

  test "an organization namespace retains GitHub identity separately from its slug" do
    assert {:ok, namespace} =
             Repositories.upsert_github_namespace(%{
               provider_account_id: 115_798_681,
               provider_node_id: "O_kgDOBubymQ",
               slug: "OpenAgentsInc",
               kind: "organization"
             })

    assert %Namespace{
             provider: "github",
             provider_account_id: 115_798_681,
             provider_node_id: "O_kgDOBubymQ",
             slug_key: "openagentsinc",
             kind: "organization",
             owner_user_id: nil
           } = namespace
  end

  test "reserved product paths cannot become repository namespaces" do
    assert {:error, changeset} =
             Repositories.upsert_github_namespace(%{
               provider_account_id: 9_999_991,
               slug: "repositories",
               kind: "organization"
             })

    assert {"is reserved", _metadata} = changeset.errors[:slug_key]
  end
end
