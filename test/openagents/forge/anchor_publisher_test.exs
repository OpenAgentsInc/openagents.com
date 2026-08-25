defmodule OpenAgents.Forge.AnchorPublisherTest do
  @moduledoc """
  Tests for the scheduled WAL anchor publisher.

  The publisher reads the WAL and writes a public commitment at
  `/.well-known/openagents-forge-anchor.json`. It is not on the push path,
  and a failing or slow publication must not refuse a push.
  """

  use OpenAgents.DataCase, async: false

  import ExUnit.CaptureLog

  alias OpenAgents.Forge.{Anchor, AnchorPublisher, Verification, WAL}
  alias OpenAgents.Repo

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  defmodule FailingAnchor do
    @moduledoc "Injectable publication dependency that always fails."
    def publish, do: {:error, :injected}
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base =
      Path.join(System.tmp_dir!(), "forge-anchor-publisher-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    OpenAgents.Forge.CacheReadiness.reset()

    user = OpenAgents.AccountsFixtures.repository_user_fixture("anchor-owner")

    {:ok, repository, :created} =
      OpenAgents.Repositories.create_user_repository(
        user,
        %{name: "demo"},
        "anchor-pub-#{System.unique_integer([:positive])}"
      )

    repository =
      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> Repo.update!()

    {:ok, _api_token, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "anchor publisher test",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)
      OpenAgents.Forge.CacheReadiness.reset()
      File.rm_rf(base)
    end)

    %{
      base: base,
      repo: repository.storage_key,
      repository: repository,
      url: "http://x:#{plaintext}@127.0.0.1:#{port}/anchor-owner/demo.git"
    }
  end

  describe "published anchor" do
    test "matches the WAL head and verifies clean, while a doctored anchor mismatches",
         context do
      publish_repository!(context)
      seed_history!(context)

      assert {:ok, published} = AnchorPublisher.publish()
      head = document_head!(published, context)

      {:ok, _generation, index} = WAL.read_index(context.repo)
      entry = List.last(WAL.entries(index))
      assert entry["seq"] == head.seq
      assert WAL.entry_link(entry) == head.link

      assert {:ok, %{findings: []}} = Verification.verify(context.repo, anchor: head)

      doctored = %{head | link: String.duplicate("0", 64)}

      assert {:error, %{findings: findings}} =
               Verification.verify(context.repo, anchor: doctored)

      assert %{"seq" => mismatch_seq} = detail(findings, "anchor_mismatch")
      assert mismatch_seq == head.seq
    end
  end

  describe "off the push path" do
    test "a failing publisher does not refuse a persisted push", context do
      seed_history!(context)
      previous_impl = Application.get_env(:openagents, :forge_anchor_publish_impl)
      Application.put_env(:openagents, :forge_anchor_publish_impl, FailingAnchor)
      on_exit(fn -> restore_env(:forge_anchor_publish_impl, previous_impl) end)

      assert {:error, :injected} = AnchorPublisher.publish()

      output = commit_and_push!(work_dir(context), "b.txt", "b\n", "b")
      {seq, link} = wal_receipt!(output)

      assert seq == 1
      assert link =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "failure degradation" do
    test "keeps the previous anchor and reports the failure", _context do
      assert {:ok, first} = AnchorPublisher.publish()

      previous_impl = Application.get_env(:openagents, :forge_anchor_publish_impl)
      Application.put_env(:openagents, :forge_anchor_publish_impl, FailingAnchor)
      on_exit(fn -> restore_env(:forge_anchor_publish_impl, previous_impl) end)

      log =
        capture_log([level: :warning], fn ->
          assert {:error, :injected} = AnchorPublisher.publish()
        end)

      assert log =~ "forge_wal_anchor_publish_failed code=injected"
      assert Anchor.latest().anchor_seq == first.anchor_seq
      assert Anchor.latest().digest == first.digest
    end
  end

  describe "idempotent republishing" do
    test "does not produce a contradictory anchor for an unchanged index", context do
      publish_repository!(context)
      seed_history!(context)

      assert {:ok, first} = AnchorPublisher.publish()
      assert {:ok, second} = AnchorPublisher.publish()

      assert second.anchor_seq == first.anchor_seq + 1
      assert second.previous_digest == first.digest
      assert repository_section(first, context) == repository_section(second, context)
      refute second.digest == first.digest
    end
  end

  defp publish_repository!(context) do
    context.repository
    |> Ecto.Changeset.change(visibility: "public")
    |> Repo.update!()
  end

  defp document_head!(anchor, context) do
    case repository_section(anchor, context) do
      %{"head_seq" => seq, "head_link" => link} when is_integer(seq) and is_binary(link) ->
        %{seq: seq, link: link}

      other ->
        flunk("the published anchor carried no head for the repository: #{inspect(other)}")
    end
  end

  defp repository_section(anchor, context) do
    path = "#{context.repository.owner}/#{context.repository.name}"

    anchor.body
    |> Jason.decode!()
    |> Map.fetch!("repositories")
    |> Enum.find(&(&1["repo"] == path))
  end

  defp seed_history!(context) do
    work = work_dir(context)

    unless File.exists?(work) do
      sh!(context.base, "git", ["clone", context.url, work])
      sh!(work, "git", ["config", "user.email", "test@example.com"])
      sh!(work, "git", ["config", "user.name", "Forge Test"])
      commit_and_push!(work, "one.txt", "one\n", "one")
    end

    :ok
  end

  defp commit_and_push!(work, filename, contents, message) do
    File.write!(Path.join(work, filename), contents)
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", message])
    sh!(work, "git", ["push", "origin", "HEAD:main"])
  end

  defp wal_receipt!(output) do
    case Regex.run(~r/openagents wal-receipt seq=(\d+) link=([0-9a-f]{64})/, output) do
      [_line, seq, link] -> {String.to_integer(seq), link}
      nil -> flunk("git push printed no WAL receipt line:\n#{output}")
    end
  end

  defp detail(findings, code) do
    Enum.find_value(findings, fn
      %{code: ^code, detail: detail} -> detail
      _other -> nil
    end)
  end

  defp work_dir(context), do: Path.join(context.base, "work")

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp sh!(dir, "git", args), do: sh_raw!(dir, "git", ["-c", "credential.helper="] ++ args)
  defp sh!(dir, command, args), do: sh_raw!(dir, command, args)

  defp sh_raw!(dir, command, args) do
    {output, status} = System.cmd(command, args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: flunk("#{command} #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
