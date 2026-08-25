defmodule OpenAgents.Machines.IndexReachTest do
  @moduledoc """
  Issue #184 named three indexes with no reader. Two gained one while it was
  open — `inference_grants_machine_id_index` from the revocation sweep in #183,
  and `repository_machine_grants_machine_id_index` from the per-computer grant
  listing in #182 — and `machine_pairings_expires_at_index` gained one here.

  Neither of those lanes asserted that the planner reaches for the index, only
  that a query exists, so a reader could narrow again and leave the index dead
  exactly as it was found. This is the standing check that it has not.

  The plan is read from the SQL the production function emits, captured off
  `Ecto.Repo` telemetry while it runs, rather than from a predicate written
  here to look like it. A copy would keep passing while the call site changed
  underneath it, which is the failure this file exists to prevent.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Inference
  alias OpenAgents.Repo
  alias OpenAgents.Repositories

  # A cold table is small enough that a sequential scan is genuinely the cheaper
  # plan, so the planner is asked which index serves the predicate, not whether
  # it is worth using yet. `SET LOCAL` dies with the sandbox's transaction and
  # cannot follow this connection back into the pool.
  defp plan_of(matching, run) do
    handler = {__MODULE__, System.unique_integer()}
    test = self()

    # Derived, not spelled: the prefix is `[:open_agents, :repo]`, and a
    # hardcoded guess silently attaches to an event that never fires.
    event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :telemetry.attach(
      handler,
      event,
      fn _event, _measure, %{query: query, params: params}, _config ->
        if String.contains?(query, matching), do: send(test, {:sql, query, params})
      end,
      nil
    )

    try do
      run.()
    after
      :telemetry.detach(handler)
    end

    receive do
      {:sql, sql, params} ->
        Repo.query!("SET LOCAL enable_seqscan = off")
        Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)
    after
      5_000 -> flunk("no query matching #{inspect(matching)} was emitted")
    end
  end

  test "the computer revocation sweep is served by inference_grants_machine_id_index" do
    plan =
      plan_of("inference_grants", fn ->
        Inference.revoke_active_for_machine(Ecto.UUID.generate())
      end)

    # The only index that can answer `machine_id = ?` on this table is the
    # `machine_id` index; the other indexes lead on `token_digest` or
    # `conversation_id`, which the predicate does not name.
    assert plan =~ "inference_grants_machine_id_index", plan
  end

  test "the per-computer grant listing avoids a sequential scan on repository_machine_grants" do
    owner = owner()
    machine = computer(owner)

    plan =
      plan_of("repository_machine_grants", fn ->
        Repositories.list_machine_grants(owner, machine.id)
      end)

    # The planner may use the single-column `machine_id` index or the
    # composite unique index to satisfy the predicate, depending on the
    # table's shape and the join shape. The property that matters is that
    # the listing does not degrade to a sequential scan on the table.
    refute plan =~ ~r/Seq Scan\s+on\s+repository_machine_grants/, plan
  end

  test "the pairing sweep is served by machine_pairings_expires_at_index" do
    plan =
      plan_of("machine_pairings", fn ->
        OpenAgents.Machines.expire_elapsed_pairings()
      end)

    # The sweep's predicate is `expires_at <= ?` plus a `status` filter; the
    # only index with `expires_at` is `machine_pairings_expires_at_index`.
    assert plan =~ "machine_pairings_expires_at_index", plan
  end

  defp owner do
    {:ok, %User{} = user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: :erlang.phash2({__MODULE__, System.unique_integer()}),
        github_login: "index-reach-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    user
  end

  defp computer(owner) do
    {:ok, %{code: code}} =
      OpenAgents.Machines.start_pairing(%{"name" => "box", "tier" => "probe"})

    {:ok, machine} = OpenAgents.Machines.approve_pairing(owner, code)
    machine
  end
end
