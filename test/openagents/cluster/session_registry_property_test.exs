defmodule OpenAgents.Cluster.SessionRegistryPropertyTest do
  @moduledoc """
  Randomized proof of the fence invariant (M5): over many random command
  sequences, the Ra machine's replies always agree with an independent shadow
  model of "current generation + terminal?" per session. If they ever diverge, a
  zombie could slip a write past the fence — so this pins the exact property the
  cluster relies on.

  Deterministic (a fixed `:rand` seed), so a failure reproduces exactly.
  """
  use ExUnit.Case, async: true

  alias OpenAgents.Cluster.SessionRegistry, as: Reg

  @ids ~w(a b c)
  @rounds 400
  @seed {101, 202, 303}

  test "replies always match an independent shadow model of generation + terminal" do
    :rand.seed(:exsss, @seed)

    # shadow: id => %{gen: current_generation, terminal?: bool}
    initial_shadow = Map.new(@ids, &{&1, %{gen: 0, terminal?: false}})

    {_machine, _shadow} =
      Enum.reduce(1..@rounds, {Reg.init(%{}), initial_shadow}, fn _i, {machine, shadow} ->
        id = Enum.random(@ids)
        s = Map.fetch!(shadow, id)
        {command, expected, next_shadow_entry} = gen_command(id, s)

        {new_machine, reply} = Kernel.apply(Reg, :apply, [%{}, command, machine])

        assert reply == expected,
               "command #{inspect(command)} on #{inspect(s)} => #{inspect(reply)}, expected #{inspect(expected)}"

        # The committed generation in the machine never goes backwards.
        if entry = Reg.lookup(id).(new_machine) do
          assert entry.generation >= s.gen
        end

        {new_machine, Map.put(shadow, id, next_shadow_entry)}
      end)
  end

  # Produce a random command for `id`, plus the reply the shadow model predicts
  # and the shadow entry after applying it.
  defp gen_command(id, %{gen: gen, terminal?: terminal?} = s) do
    # Pick a generation that is sometimes current, sometimes stale, sometimes future.
    g = Enum.random([gen, max(gen - 1, 0), gen + 1])

    case Enum.random([:claim, :checkpoint, :finish]) do
      :claim ->
        if terminal? do
          {{:claim, id, :job, :n1}, {:error, {:terminal, gen}}, s}
        else
          {{:claim, id, :job, :n1}, {:ok, gen + 1}, %{gen: gen + 1, terminal?: false}}
        end

      :checkpoint ->
        if not terminal? and g == gen and gen > 0 do
          {{:checkpoint, id, g, %{x: 1}}, :ok, s}
        else
          {{:checkpoint, id, g, %{x: 1}}, {:fenced, fence_gen(gen)}, s}
        end

      :finish ->
        if not terminal? and g == gen and gen > 0 do
          {{:finish, id, g}, :ok, %{gen: gen, terminal?: true}}
        else
          {{:finish, id, g}, {:fenced, fence_gen(gen)}, s}
        end
    end
  end

  # Before any claim (gen 0) the session has no entry, so the fence replies nil.
  defp fence_gen(0), do: nil
  defp fence_gen(gen), do: gen
end
