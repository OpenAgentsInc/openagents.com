defmodule OpenAgents.Tools.RepositoryToolsTest do
  @moduledoc """
  The repository read family (#122): reads over the baked source tree,
  bounded search and listing, the code_check gate, and the path/authority
  refusals that keep the family inside SELF-EDIT-001.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Tools.{
    CodeCheck,
    ExecutionContext,
    Registry,
    RepoGrep,
    RepoList,
    RepoRead,
    Runner
  }

  setup do
    source = Path.join(System.tmp_dir!(), "repo-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "lib/sample.ex"), "defmodule RepoToolsFixtureSample do\nend\n")
    File.write!(Path.join(source, "README.md"), "hello forge sample\n")
    previous = Application.get_env(:openagents, :source_repo_dir)
    Application.put_env(:openagents, :source_repo_dir, source)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:openagents, :source_repo_dir, previous),
        else: Application.delete_env(:openagents, :source_repo_dir)

      File.rm_rf(source)
    end)

    {:ok, snapshot} = Registry.build([RepoRead, RepoGrep, RepoList, CodeCheck])
    %{snapshot: snapshot}
  end

  defp context do
    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:test",
      authorities: MapSet.new(["repository.read", "code.execute"])
    }
  end

  defp run(snapshot, name, arguments) do
    {:ok, outcome} =
      Runner.run(
        snapshot,
        %{
          call_id: "call-#{name}",
          name: name,
          version: 1,
          raw_arguments: Jason.encode!(arguments)
        },
        context()
      )

    outcome
  end

  test "repo_read reads a file from the baked source and refuses traversal", %{snapshot: snapshot} do
    outcome = run(snapshot, "repo_read", %{"path" => "README.md"})
    assert outcome["status"] == "succeeded"
    assert outcome["result"]["content"] =~ "hello forge"
    assert outcome["result"]["from"] == "image"

    refused = run(snapshot, "repo_read", %{"path" => "../outside.txt"})
    assert refused["status"] == "failed"
    assert refused["error"]["code"] == "invalid_repository_path"

    missing = run(snapshot, "repo_read", %{"path" => "nope.txt"})
    assert missing["error"]["code"] == "repository_file_not_found"
  end

  test "repo_grep finds bounded matches; repo_list lists the tree", %{snapshot: snapshot} do
    outcome = run(snapshot, "repo_grep", %{"pattern" => "FixtureSample"})
    assert outcome["status"] == "succeeded"
    assert [%{"path" => "lib/sample.ex", "line" => 1}] = outcome["result"]["matches"]

    bad = run(snapshot, "repo_grep", %{"pattern" => "([unclosed"})
    assert bad["error"]["code"] == "invalid_search_pattern"

    listing = run(snapshot, "repo_list", %{})
    names = Enum.map(listing["result"]["entries"], & &1["name"])
    assert "lib" in names and "README.md" in names
  end

  test "repo tools refuse without the repository authority", %{snapshot: snapshot} do
    bare_context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:test",
      authorities: MapSet.new(["conversation.read"])
    }

    {:ok, outcome} =
      Runner.run(
        snapshot,
        %{
          call_id: "call-refuse",
          name: "repo_read",
          version: 1,
          raw_arguments: Jason.encode!(%{"path" => "README.md"})
        },
        bare_context
      )

    assert outcome["status"] == "refused"
    assert outcome["error"]["code"] == "authority_refused"
  end

  test "code_check reports syntax health and skips compiling loaded modules", %{
    snapshot: snapshot
  } do
    ok = run(snapshot, "code_check", %{"content" => "defmodule CodeCheckFreshProbe do\nend\n"})
    assert ok["result"]["syntax"] == "ok"
    assert ok["result"]["compile"] == "ok"
    refute Code.ensure_loaded?(CodeCheckFreshProbe)

    broken =
      run(snapshot, "code_check", %{"content" => "defmodule Broken do\n  def x( do\nend\n"})

    assert broken["result"]["syntax"] == "error"
    assert broken["result"]["detail"] =~ "line"

    # A module the running system has loaded is never redefined by the probe.
    loaded =
      run(snapshot, "code_check", %{
        "content" => "defmodule OpenAgents.BuildInfo do\n  def revision, do: \"x\"\nend\n"
      })

    assert loaded["result"]["syntax"] == "ok"
    assert loaded["result"]["compile"] == "skipped"
    assert loaded["result"]["detail"] =~ "already loaded"
    assert OpenAgents.BuildInfo.revision() != "x"
  end
end
