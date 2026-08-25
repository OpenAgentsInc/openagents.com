defmodule OpenAgents.Forge.AssignmentGitPushTest do
  @moduledoc """
  #234: branch-scoped assignment credentials enforce ref-level limits over the
  real git HTTP path.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Repo
  alias OpenAgents.Forge.{Assignment, AssignmentCredential, CacheReadiness}
  alias OpenAgents.Box.ConversationBox

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "assignment-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    CacheReadiness.reset()

    user = repository_user_fixture("assignment-pusher")

    {:ok, repository, :created} =
      OpenAgents.Repositories.create_user_repository(
        user,
        %{name: "branch-scoped"},
        "branch-scoped-#{System.unique_integer([:positive])}"
      )

    repository =
      repository
      |> Ecto.Changeset.change(
        lifecycle_state: "ready",
        ready_at: DateTime.utc_now(),
        default_branch: "develop",
        protected_branches: ["agent/protected-1"]
      )
      |> Repo.update!()

    {:ok, conversation} =
      OpenAgents.Conversations.ensure_conversation(
        "assignment-git-#{System.unique_integer([:positive])}"
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    box = fn id ->
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_#{id}_#{System.unique_integer([:positive])}",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert!()
    end

    assigned_issue = issue!(repository, "Assigned branch issue")
    assigned_box = box.("assigned")

    assigned_assignment =
      %Assignment{}
      |> Assignment.changeset(%{
        conversation_box_id: assigned_box.id,
        repository_id: repository.id,
        issue_id: assigned_issue.id,
        requesting_principal: %{
          "type" => "user",
          "id" => user.id,
          "actor_type" => "user",
          "actor_id" => user.id
        },
        branch: "agent/issue-1",
        deadline_at: DateTime.add(now, 3600, :second),
        admitted_at: now
      })
      |> Repo.insert!()

    {assigned_token, _assigned_credential} =
      create_credential(assigned_assignment, repository, "agent/issue-1")

    protected_issue = issue!(repository, "Protected branch issue")
    protected_box = box.("protected")

    protected_assignment =
      %Assignment{}
      |> Assignment.changeset(%{
        conversation_box_id: protected_box.id,
        repository_id: repository.id,
        issue_id: protected_issue.id,
        requesting_principal: %{
          "type" => "user",
          "id" => user.id,
          "actor_type" => "user",
          "actor_id" => user.id
        },
        branch: "agent/protected-1",
        deadline_at: DateTime.add(now, 3600, :second),
        admitted_at: now
      })
      |> Repo.insert!()

    {protected_token, _protected_credential} =
      create_credential(protected_assignment, repository, "agent/protected-1")

    default_issue = issue!(repository, "Default branch issue")
    default_box = box.("default")

    default_assignment =
      %Assignment{}
      |> Assignment.changeset(%{
        conversation_box_id: default_box.id,
        repository_id: repository.id,
        issue_id: default_issue.id,
        requesting_principal: %{
          "type" => "user",
          "id" => user.id,
          "actor_type" => "user",
          "actor_id" => user.id
        },
        branch: repository.default_branch,
        deadline_at: DateTime.add(now, 3600, :second),
        admitted_at: now
      })
      |> Repo.insert!()

    {default_branch_token, _default_credential} =
      create_credential(default_assignment, repository, repository.default_branch)

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      if previous_data,
        do: Application.put_env(:openagents, :forge_data_dir, previous_data),
        else: Application.delete_env(:openagents, :forge_data_dir)

      if previous_wal,
        do: Application.put_env(:openagents, :forge_wal_dir, previous_wal),
        else: Application.delete_env(:openagents, :forge_wal_dir)

      CacheReadiness.reset()
      File.rm_rf(base)
    end)

    work =
      seed_clone!(
        base,
        "http://x:#{assigned_token}@127.0.0.1:#{port}/assignment-pusher/branch-scoped.git"
      )

    %{
      work: work,
      repository: repository,
      port: port,
      assigned_token: assigned_token,
      protected_token: protected_token,
      default_branch_token: default_branch_token
    }
  end

  describe "branch-scoped assignment credentials over git-receive-pack" do
    test "pushing to the repository default branch with the assigned credential is refused",
         context do
      %{work: work, port: port, assigned_token: assigned_token} = context
      commit!(work, "Default branch commit")

      url =
        "http://x:#{assigned_token}@127.0.0.1:#{port}/assignment-pusher/branch-scoped.git"

      {_output, status} = git(work, ["push", url, "HEAD:develop"])
      assert status != 0
    end

    test "pushing to the assigned branch with the assigned credential succeeds", context do
      %{work: work} = context
      commit!(work, "Assigned branch commit")
      git!(work, ["push", "origin", "HEAD:agent/issue-1"])
    end

    test "pushing to another non-assigned branch with the assigned credential is refused",
         context do
      %{work: work} = context
      commit!(work, "Other branch commit")
      {_output, status} = git(work, ["push", "origin", "HEAD:agent/other"])
      assert status != 0
    end

    test "pushing to a protected branch is refused", context do
      %{work: work, port: port, protected_token: protected_token} = context
      commit!(work, "Protected branch commit")

      url =
        "http://x:#{protected_token}@127.0.0.1:#{port}/assignment-pusher/branch-scoped.git"

      {_output, status} = git(work, ["push", url, "HEAD:agent/protected-1"])
      assert status != 0
    end

    test "a credential for the default branch itself is refused", context do
      %{
        work: work,
        port: port,
        repository: repository,
        default_branch_token: default_branch_token
      } =
        context

      commit!(work, "Default branch credential commit")

      url =
        "http://x:#{default_branch_token}@127.0.0.1:#{port}/assignment-pusher/branch-scoped.git"

      {_output, status} = git(work, ["push", url, "HEAD:#{repository.default_branch}"])
      assert status != 0
    end
  end

  # Mints the way `Assignments.persist_assignment/7` mints: the token carries
  # the *assignment* id and the credential row takes its own autogenerated key.
  #
  # This helper used to set `%AssignmentCredential{id: credential_id}` and
  # embed that credential id in the token, which is the shape `authenticate/1`
  # read but not the shape production wrote. The branch-policy tests below
  # therefore passed against a credential no real assignment could produce,
  # and a credential that could never authenticate shipped underneath them.
  defp create_credential(assignment, repository, branch) do
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    plaintext = "oa_assignment_" <> assignment.id <> "." <> secret
    digest = :crypto.hash(:sha256, plaintext)

    credential =
      %AssignmentCredential{}
      |> AssignmentCredential.changeset(%{
        assignment_id: assignment.id,
        token_digest: digest,
        last_four: String.slice(secret, -4, 4),
        repository_id: repository.id,
        branch: branch,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Repo.insert!()

    {plaintext, credential}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp git!(dir, args) do
    {output, status} =
      System.cmd("git", ["-c", "credential.helper="] ++ args,
        cd: dir,
        stderr_to_stdout: true,
        env: [{"GIT_TERMINAL_PROMPT", "0"}]
      )

    if status != 0, do: flunk("git #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end

  defp git(dir, args) do
    System.cmd("git", ["-c", "credential.helper="] ++ args,
      cd: dir,
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"}]
    )
  end

  defp seed_clone!(base, url) do
    work = Path.join(base, "work")
    git!(base, ["clone", url, work])
    git!(work, ["config", "user.email", "assignment@example.com"])
    git!(work, ["config", "user.name", "Assignment"])
    git!(work, ["symbolic-ref", "HEAD", "refs/heads/main"])
    work
  end

  defp commit!(work, message) do
    name = "file-#{System.unique_integer([:positive])}.txt"
    File.write!(Path.join(work, name), message)
    git!(work, ["add", "-A"])
    git!(work, ["commit", "-m", message])
    work |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp issue!(repository, title) do
    {:ok, issue} = OpenAgents.Issues.create_issue(repository, %{title: title})
    issue
  end
end
