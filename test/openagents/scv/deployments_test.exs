defmodule OpenAgents.SCV.DeploymentsTest do
  @moduledoc """
  SCV-001: the lane that spends OpenAgents capacity.

  These tests exercise the refusals first — a non-operator, a disabled feature,
  an oversized objective, a full concurrency ceiling — and then run one
  deployment end to end against a fake OpenCode binary, so the admitted model
  slug is proved to reach the process invocation rather than only the
  configuration.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.AccountsFixtures
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Repositories
  alias OpenAgents.RuntimeConfig
  alias OpenAgents.SCV.Deployments
  alias OpenAgents.Tools.{ExecutionContext, ScvDeploy}
  alias OpenAgents.Work.{Job, Scv}

  @model "opencode/x-preview-f-free"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "scv-deploy-#{System.unique_integer([:positive])}")
    executable = Path.join(root, "fake-opencode")
    File.mkdir_p!(root)
    File.write!(executable, fake_opencode())
    File.chmod!(executable, 0o700)

    previous =
      for key <- [:forge_data_dir, :scv_deploy, :admin_github_ids] do
        {key, Application.get_env(:openagents, key)}
      end

    Application.put_env(:openagents, :forge_data_dir, Path.join(root, "forge"))

    Application.put_env(:openagents, :scv_deploy,
      enabled: true,
      model: @model,
      reasoning_effort: "low",
      opencode_api_key: nil,
      executable: executable,
      concurrency_limit: 2,
      wall_clock_ms: 60_000,
      maximum_output_bytes: 65_536,
      output_root: Path.join(root, "runs")
    )

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:openagents, key),
          else: Application.put_env(:openagents, key, value)
      end

      File.rm_rf(root)
    end)

    %{root: root}
  end

  describe "operator authority" do
    test "a signed-in non-operator is refused by the code that starts the run" do
      %{user: user, conversation: conversation} = account("scv-non-operator")

      assert {:error, :operator_required} =
               Deployments.start(user, %{
                 conversation_id: conversation.id,
                 owner_visitor_id: conversation.visitor_id,
                 surface: "text",
                 repository: "OpenAgentsInc/openagents.com",
                 objective: "Describe the README."
               })

      # Nothing was written and nothing was spawned.
      assert Deployments.active_count() == 0
    end

    test "the tool refuses a non-operator even though the catalog advertises it" do
      %{user: user, conversation: conversation} = account("scv-tool-non-operator")
      _repository = seed_repository!(user, "scvtool", "sample")

      assert {:error, :operator_required} =
               ScvDeploy.execute(
                 %{"repository" => "scvtool/sample", "objective" => "Describe the README."},
                 context(conversation)
               )

      assert Deployments.active_count() == 0
    end

    test "only an operator receives the approval receipt the surface policy demands" do
      %{user: user} = account("scv-receipts")
      %{user: operator} = operator_account("scv-receipts-operator")

      assert Deployments.approval_receipts(user, "conversation:abc") == []
      assert Deployments.approval_receipts(nil, "conversation:abc") == []

      assert [receipt] = Deployments.approval_receipts(operator, "conversation:abc")
      assert receipt["schema"] == "sarah.module_approval.v1"
      assert receipt["approval_class"] == "explicit_operator_approval"
      assert receipt["module_id"] == "sarah.tool.scv_deploy.v1"
      assert receipt["actor_type"] == "operator"
      assert receipt["explicit"] == true
      assert receipt["receipt_ref"] == "operator:#{operator.id}"
    end
  end

  describe "bounds" do
    test "a disabled lane refuses before authority is even considered" do
      settings = Application.fetch_env!(:openagents, :scv_deploy)
      Application.put_env(:openagents, :scv_deploy, Keyword.put(settings, :enabled, false))

      %{user: operator, conversation: conversation} = operator_account("scv-disabled")

      assert {:error, :scv_deploy_disabled} =
               Deployments.start(operator, %{
                 conversation_id: conversation.id,
                 owner_visitor_id: conversation.visitor_id,
                 surface: "text",
                 repository: "scvbounds/sample",
                 objective: "Describe the README."
               })
    end

    test "an objective past its bound is refused" do
      %{user: operator, conversation: conversation} = operator_account("scv-objective")

      for objective <- ["", "   ", String.duplicate("a", Scv.maximum_objective_bytes() + 1)] do
        assert {:error, :scv_objective_invalid} =
                 Deployments.start(operator, %{
                   conversation_id: conversation.id,
                   owner_visitor_id: conversation.visitor_id,
                   surface: "text",
                   repository: "scvbounds/sample",
                   objective: objective
                 })
      end
    end

    test "an unknown repository is refused before any process starts" do
      %{user: operator, conversation: conversation} = operator_account("scv-repository")

      assert {:error, :scv_repository_not_found} =
               Deployments.start(operator, %{
                 conversation_id: conversation.id,
                 owner_visitor_id: conversation.visitor_id,
                 surface: "text",
                 repository: "nobody/nothing",
                 objective: "Describe the README."
               })

      # A filesystem path is not a repository name, and never becomes one.
      assert {:error, :scv_repository_not_found} =
               Deployments.start(operator, %{
                 conversation_id: conversation.id,
                 owner_visitor_id: conversation.visitor_id,
                 surface: "text",
                 repository: "/etc",
                 objective: "Describe the README."
               })
    end

    test "the concurrency ceiling refuses the run rather than queueing it" do
      %{user: operator, conversation: conversation} = operator_account("scv-capacity")
      repository = seed_repository!(operator, "scvcap", "sample")

      settings = Application.fetch_env!(:openagents, :scv_deploy)
      Application.put_env(:openagents, :scv_deploy, Keyword.put(settings, :concurrency_limit, 1))

      # One job already occupies the single admitted slot.
      {:ok, _running} =
        OpenAgents.Work.create_job(%{
          conversation_id: conversation.id,
          owner_visitor_id: conversation.visitor_id,
          surface: "text",
          goal: "an SCV already holding the slot",
          kind: "scv"
        })

      assert Deployments.active_count() == 1

      assert {:error, :scv_capacity_reached} =
               Deployments.start(operator, %{
                 conversation_id: conversation.id,
                 owner_visitor_id: conversation.visitor_id,
                 surface: "text",
                 repository: "#{repository.owner}/#{repository.name}",
                 objective: "Describe the README."
               })
    end

    test "the runtime configuration refuses the lane without the work lane or bounds" do
      settings = Application.get_all_env(:openagents) |> Map.new()

      enabled =
        Map.put(settings, :scv_deploy, Keyword.put(base_deploy_settings(), :enabled, true))

      assert {:error, %{setting: :scv_deploy, reason: "requires the work lane"}} =
               RuntimeConfig.validate(
                 enabled
                 |> Map.put(:work, enabled: false)
                 |> Map.put(:work_workers_enabled, false)
               )

      unbounded =
        Map.put(
          enabled,
          :scv_deploy,
          base_deploy_settings()
          |> Keyword.put(:enabled, true)
          |> Keyword.put(:concurrency_limit, 100)
        )

      work_enabled =
        unbounded
        |> Map.put(:work, enabled: true)
        |> Map.put(:work_workers_enabled, true)

      assert {:error, %{setting: :scv_deploy, reason: reason}} =
               RuntimeConfig.validate(work_enabled)

      assert reason == "requires an admitted model, bounds, and output root"
    end
  end

  describe "an admitted deployment" do
    test "runs the admitted model on our capacity and reports back into the conversation" do
      %{user: operator, conversation: conversation} = operator_account("scv-run")
      repository = seed_repository!(operator, "scvrun", "sample")

      assert {:ok, job} =
               Deployments.start(operator, %{
                 conversation_id: conversation.id,
                 owner_visitor_id: conversation.visitor_id,
                 surface: "text",
                 repository: "#{repository.owner}/#{repository.name}",
                 objective: "Describe the README."
               })

      assert job.kind == "scv"
      assert job.machine_id == nil

      # The authority is snapshotted at admission, not read at run time.
      assert job.authority_snapshot["model"] == @model
      assert job.authority_snapshot["permission_profile"] == "read_only"
      assert job.authority_snapshot["driver"] == "opencode"
      assert job.authority_snapshot["repository_id"] == repository.id
      assert job.authority_snapshot["operator_user_id"] == operator.id
      assert Regex.match?(~r/\A[0-9a-f]{40}\z/, job.authority_snapshot["repository_revision"])
      assert job.budget_snapshot["wall_clock_ms"] == 60_000
      assert job.budget_snapshot["maximum_output_bytes"] == 65_536

      terminal = await_terminal(job.id)
      assert terminal.status == "completed"

      # The fake binary echoes what it was invoked with, so this asserts the
      # slug reached the process, not merely the configuration.
      assert terminal.report =~ "model=#{@model}"
      assert terminal.report =~ "fetch=0"
      assert terminal.report =~ "openai_key=absent"
      assert terminal.report =~ "SCV deployment on scvrun/sample"

      # The report is a durable assistant message in the conversation.
      assert terminal.report_message_id != nil

      # The disposable workspace does not outlive the run. Cleanup happens after
      # the terminal row commits, so this waits for it rather than racing it.
      assert await_removed(terminal.delegation["workspace_path"])
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp base_deploy_settings do
    [
      model: @model,
      reasoning_effort: "low",
      concurrency_limit: 2,
      wall_clock_ms: 900_000,
      maximum_output_bytes: 16_777_216,
      output_root: "/var/lib/openagents/scv/opencode-runs"
    ]
  end

  defp account(login) do
    user = AccountsFixtures.repository_user_fixture(login)
    {:ok, conversation} = Conversations.ensure_conversation(user)
    %{user: user, conversation: conversation}
  end

  defp operator_account(login) do
    %{user: user} = built = account(login)
    configured = Application.get_env(:openagents, :admin_github_ids, [])
    Application.put_env(:openagents, :admin_github_ids, [user.github_id | configured])
    built
  end

  defp context(conversation) do
    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{conversation.id}",
      authorities: MapSet.new(["scv.deploy"]),
      surface: "text",
      conversation_id: conversation.id,
      owner_visitor_id: conversation.visitor_id
    }
  end

  defp seed_repository!(user, owner, name) do
    {:ok, repository} =
      Repositories.create_repository(%{
        owner: owner,
        name: name,
        visibility: "public",
        default_branch: "main",
        created_by_user_id: user.id
      })

    path = Repos.ensure_repo!(repository.storage_key, "main")
    {blob, 0} = plumb(path, ["hash-object", "-w", "--stdin"], "an SCV fixture repository\n")
    {tree, 0} = plumb(path, ["mktree"], "100644 blob #{String.trim(blob)}\tREADME.md\n")

    {commit, 0} =
      plumb(path, ["commit-tree", String.trim(tree), "-m", "seed"], "",
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]
      )

    {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/main", String.trim(commit)])
    repository
  end

  defp plumb(path, args, stdin, options \\ []) do
    input = Path.join(System.tmp_dir!(), "plumb-#{System.unique_integer([:positive])}")
    File.write!(input, stdin)

    try do
      System.cmd(
        "sh",
        ["-c", ~s(exec git --git-dir "$GD" "$@" < "$IN"), "sh"] ++ args,
        env: [{"GD", path}, {"IN", input}] ++ Keyword.get(options, :env, [])
      )
    after
      File.rm(input)
    end
  end

  defp await_terminal(job_id) do
    Enum.reduce_while(1..200, nil, fn _attempt, _accumulator ->
      job = Repo.get!(Job, job_id)

      if job.status in Job.terminal_statuses() do
        {:halt, job}
      else
        Process.sleep(50)
        {:cont, job}
      end
    end)
  end

  defp await_removed(path) when is_binary(path) do
    Enum.reduce_while(1..100, false, fn _attempt, _accumulator ->
      if File.exists?(path) do
        Process.sleep(20)
        {:cont, false}
      else
        {:halt, true}
      end
    end)
  end

  # Echoes the invocation back as one OpenCode text event, so the test can
  # assert on what the process actually received.
  defp fake_opencode do
    """
    #!/bin/sh
    model=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --model) model="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    prompt=$(cat)
    if [ -z "$prompt" ]; then exit 30; fi
    if [ "${OPENAI_API_KEY+x}" = "x" ]; then openai_key=present; else openai_key=absent; fi
    printf '{"type":"text","timestamp":1,"sessionID":"ses_scv","part":{"type":"text","text":"model=%s fetch=%s openai_key=%s"}}\\n' \\
      "$model" "${OPENCODE_DISABLE_MODELS_FETCH}" "$openai_key"
    """
  end
end
