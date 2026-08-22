defmodule OpenAgents.Release.AppupTest do
  @moduledoc """
  Proves the packaged appup describes the two revisions it was built from.

  `:systools.make_relup/4` copies the appup into the relup verbatim, so an
  instruction list that names a fixed set of modules installs only those
  modules. A node would then run an interleaved mixture of two revisions while
  `verify` passed and `BuildInfo.revision/0` reported the new SHA. These tests
  drive `rel/openagents.appup.exs`, the file the release actually ships.
  """
  use ExUnit.Case, async: false

  alias OpenAgents.Release.Appup

  @appup_file Path.expand("../../../rel/openagents.appup.exs", __DIR__)
  @environment [
    "RELUP_FROM",
    "RELUP_TO",
    "RELUP_FROM_EBIN",
    "RELUP_TO_EBIN",
    "RELUP_FROM_STATE",
    "RELUP_TO_STATE"
  ]

  setup do
    previous = Map.new(@environment, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "covers a changed module the fixed proof set never named" do
    from = ebin([widget(1), only_in_from()])
    to = ebin([widget(2), only_in_to()])

    {~c"0.3.0", [{~c"0.2.0", up}], [{~c"0.2.0", down}]} =
      generate(from, to, "0.2.0", "0.3.0", 2, 2)

    assert {:load_module, Relup.Fixture.Widget} in up
    assert {:load_module, Relup.Fixture.Widget} in down

    assert {:add_module, Relup.Fixture.OnlyInTo} in up
    assert {:delete_module, Relup.Fixture.OnlyInFrom} in up
    assert {:add_module, Relup.Fixture.OnlyInFrom} in down
    assert {:delete_module, Relup.Fixture.OnlyInTo} in down

    assert {:apply, {OpenAgents.ReleaseState, :install_barrier, []}} in up
    assert {:apply, {OpenAgents.ReleaseState, :install_barrier, []}} in down
  end

  test "leaves untouched modules alone" do
    from = ebin([widget(1), stable()])
    to = ebin([widget(2), stable()])

    {_version, [{_from, up}], _down} = generate(from, to, "0.2.0", "0.3.0", 2, 2)

    assert {:load_module, Relup.Fixture.Widget} in up
    refute {:load_module, Relup.Fixture.Stable} in up
  end

  test "carries each direction's target state schema in the advanced update" do
    from = ebin([widget(1)])
    to = ebin([widget(2)])

    {_version, [{_from, up}], [{_to, down}]} = generate(from, to, "0.1.0", "0.2.0", 1, 2)

    assert {:update, OpenAgents.ReleaseState, {:advanced, [schema_version: 2]}} in up
    assert {:update, OpenAgents.ReleaseState, {:advanced, [schema_version: 1]}} in down
  end

  test "keeps a same-schema pair on its schema in both directions" do
    from = ebin([widget(1)])
    to = ebin([widget(2)])

    {_version, [{_from, up}], [{_to, down}]} = generate(from, to, "0.2.0", "0.3.0", 2, 2)

    assert {:update, OpenAgents.ReleaseState, {:advanced, [schema_version: 2]}} in up
    assert {:update, OpenAgents.ReleaseState, {:advanced, [schema_version: 2]}} in down
  end

  test "updates a supervisor rather than loading it" do
    from = ebin([supervisor(1)])
    to = ebin([supervisor(2)])

    {_version, [{_from, up}], _down} = generate(from, to, "0.2.0", "0.3.0", 2, 2)

    assert {:update, Relup.Fixture.Tree, :supervisor} in up
  end

  test "refuses to emit an instruction list without the from build" do
    to = ebin([widget(2)])

    System.put_env("RELUP_FROM", "0.2.0")
    System.put_env("RELUP_TO", "0.3.0")
    System.put_env("RELUP_TO_EBIN", to)
    System.put_env("RELUP_FROM_STATE", "2")
    System.put_env("RELUP_TO_STATE", "2")
    System.delete_env("RELUP_FROM_EBIN")

    assert_raise RuntimeError, ~r/RELUP_FROM_EBIN/, fn -> Code.eval_file(@appup_file) end
  end

  test "refuses one version without the other" do
    System.put_env("RELUP_TO", "0.3.0")
    System.delete_env("RELUP_FROM")

    assert_raise RuntimeError, ~r/must be set together/, fn -> Code.eval_file(@appup_file) end
  end

  test "verify_relup! rejects a relup that omits a changed module" do
    from = ebin([widget(1)])
    to = ebin([widget(2)])

    path = Path.join(directory(), "relup")

    File.write!(path, ~s|{"0.3.0",[{"0.2.0","",[]}],[{"0.2.0","",[]}]}.\n|)

    assert_raise RuntimeError, ~r/Relup.Fixture.Widget/, fn ->
      Appup.verify_relup!(path,
        from_ebin: from,
        to_ebin: to,
        from_state_version: 2,
        to_state_version: 2
      )
    end
  end

  test "verify_relup! accepts a relup that names every covered module" do
    from = ebin([widget(1)])
    to = ebin([widget(2)])

    {_version, [{_from, up}], [{_to, down}]} = generate(from, to, "0.2.0", "0.3.0", 2, 2)
    path = Path.join(directory(), "relup")

    File.write!(
      path,
      :io_lib.format(~c"~tp.~n", [{~c"0.3.0", [{~c"0.2.0", ~c"", up}], [{~c"0.2.0", ~c"", down}]}])
    )

    assert OpenAgents.ReleaseState in Appup.verify_relup!(path,
             from_ebin: from,
             to_ebin: to,
             from_state_version: 2,
             to_state_version: 2
           )
  end

  defp generate(from_ebin, to_ebin, from_version, to_version, from_state, to_state) do
    System.put_env("RELUP_FROM", from_version)
    System.put_env("RELUP_TO", to_version)
    System.put_env("RELUP_FROM_EBIN", from_ebin)
    System.put_env("RELUP_TO_EBIN", to_ebin)
    System.put_env("RELUP_FROM_STATE", to_string(from_state))
    System.put_env("RELUP_TO_STATE", to_string(to_state))

    {appup, []} = Code.eval_file(@appup_file)
    appup
  end

  defp ebin(sources) do
    directory = directory()

    state_beam = OpenAgents.ReleaseState |> :code.which() |> to_string()
    File.cp!(state_beam, Path.join(directory, Path.basename(state_beam)))

    Enum.each(sources, &compile_into(directory, &1))
    directory
  end

  defp directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "openagents-appup-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp compile_into(directory, source) do
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      for {module, binary} <- Code.compile_string(source) do
        File.write!(Path.join(directory, "#{module}.beam"), binary)
        :code.purge(module)
        :code.delete(module)
      end
    after
      Code.compiler_options(previous)
    end
  end

  defp widget(value) do
    "defmodule Relup.Fixture.Widget do def value, do: #{value} end"
  end

  defp stable do
    "defmodule Relup.Fixture.Stable do def value, do: :stable end"
  end

  defp only_in_from do
    "defmodule Relup.Fixture.OnlyInFrom do def value, do: :gone end"
  end

  defp only_in_to do
    "defmodule Relup.Fixture.OnlyInTo do def value, do: :new end"
  end

  defp supervisor(value) do
    """
    defmodule Relup.Fixture.Tree do
      use Supervisor
      @impl true
      def init(_arguments), do: Supervisor.init([], strategy: :one_for_one, max_restarts: #{value})
    end
    """
  end
end
