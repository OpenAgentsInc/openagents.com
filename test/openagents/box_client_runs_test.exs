defmodule OpenAgents.BoxClientRunsTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Box.Client

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_api = Application.get_env(:openagents, :box_api)
    original_key = Application.get_env(:openagents, :box_api_key)

    Application.put_env(:openagents, :box_api,
      base_url: "https://box-api.internal",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    Application.put_env(:openagents, :box_api_key, "box-client-test")

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)
  end

  test "dispatch uses one detached mkdir-and-launch command", do: begin_dispatch()

  test "assignment dispatch keeps credential setup outside the child shell" do
    token = "oa_assignment_11111111-1111-4111-8111-111111111111.secret-token"
    run_directory = "/home/box-user/.openagents/box-runs"

    Req.Test.expect(__MODULE__, fn request ->
      command = request.body_params["command"]

      assert request.body_params["env"] == %{"OPENAGENTS_FORGE_TOKEN" => token}
      refute command =~ token

      assert command =~ "root=#{run_directory}"
      assert command =~ ~s(> "$root/forge-credential")
      assert command =~ ~s(git config --file="$root/gitconfig")
      assert command =~ ~s(env GIT_CONFIG_GLOBAL="$root/gitconfig")

      assert command =~ "unset OPENAGENTS_FORGE_TOKEN"
      refute command =~ "credential_setup"

      script_path =
        Path.join(
          System.tmp_dir!(),
          "assignment-dispatch-#{System.unique_integer([:positive])}.sh"
        )

      on_exit(fn -> File.rm(script_path) end)
      assert :ok = File.write(script_path, command)
      assert {_output, 0} = System.cmd("sh", ["-n", script_path])

      Req.Test.json(request, %{"stdout" => "4242\n"})
    end)

    assert {:ok, 4242} =
             Client.dispatch_run(
               "bx_8bhkse3n",
               "11111111-1111-4111-8111-111111111111",
               "git push https://openagents.com/repo.git",
               run_directory,
               token
             )
  end

  test "poll decodes bounded output from a recorded offset" do
    encoded = Base.encode64("hello")

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/boxes/bx_8bhkse3n/commands"
      body = request.body_params
      assert body["command"] =~ "OA_SIZE"
      assert body["command"] =~ "dd"

      Req.Test.json(request, %{
        "stdout" => "OA_PRESENT=1\nOA_SIZE=5\nOA_DATA=#{encoded}\nOA_ALIVE=1\n"
      })
    end)

    assert {:ok, %{present: true, log_size: 5, output: "hello", exit_status: nil, alive: true}} =
             Client.poll_run("bx_8bhkse3n", "11111111-1111-4111-8111-111111111111", 0)
  end

  test "an exit sentinel is parsed as an integer status" do
    Req.Test.expect(__MODULE__, fn request ->
      Req.Test.json(request, %{
        "stdout" => "OA_PRESENT=1\nOA_SIZE=0\nOA_DATA=\nOA_EXIT=17\nOA_ALIVE=0\n"
      })
    end)

    assert {:ok, %{exit_status: 17, alive: false}} =
             Client.poll_run("bx_8bhkse3n", "11111111-1111-4111-8111-111111111111", 0)
  end

  defp begin_dispatch do
    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/boxes/bx_8bhkse3n/commands"
      body = request.body_params
      assert body["timeoutSeconds"] == 30
      assert body["command"] =~ "mkdir"
      assert body["command"] =~ "setsid"
      assert body["command"] =~ "output.log"
      assert body["command"] =~ "exit-code"
      Req.Test.json(request, %{"stdout" => "4242\n"})
    end)

    assert {:ok, 4242} =
             Client.dispatch_run(
               "bx_8bhkse3n",
               "11111111-1111-4111-8111-111111111111",
               "echo detached"
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
