defmodule OpenAgents.Forge.DeploymentLane do
  @moduledoc """
  Chooses a candidate's deployment lane before any node is touched.

  RELEASE-005 names three lanes: the transactional direct BEAM load, the
  two-way relup, and digest-addressed rolling replacement. Until now only two
  inputs reached that choice — the build manifest's structural classification
  and the hot-load allowlist — and both describe the *candidate*. Nothing asked
  the *fleet* whether it could survive the lane it was about to be given.

  `OpenAgents.Forge.RelupTopology` answers that question, and RELEASE-008 makes
  `OpenAgents.Forge.RelupNode.check_topology/2` the first preinstall step so an
  incompatible fleet refuses before `install_release` reaches its point of no
  return. That refusal is the backstop, and it stays. What it cannot do is
  choose: a candidate reaches rolling replacement by being refused rather than
  by being classified, and the reason is discovered one node at a time instead
  of once, in front.

  This module reads the verdict first and folds it into the classification, so
  the lane is a decision with a recorded reason rather than the residue of a
  failure.

  ## The verdict is a runtime read, not a gate artifact

  The release gate proves the RELEASE-008 refusal against the running `libring`
  application, and it keeps doing so. It does not publish a per-candidate
  topology verdict, because a verdict is a property of the fleet rather than of
  the candidate bytes: the gate runs on a builder that is not the fleet, and a
  fleet node can restart into a different application set between the gate and
  the deployment. The only reading that is true when the lane is chosen is the
  one taken from the fleet immediately before choosing, which is what
  `fleet_topology/1` does.

  ## Why `relup` is not selectable today

  Two conditions gate it, and both must hold. The fleet's topology verdict must
  support relup, which no fleet running `libring` does — `HashRing.App.start/2`
  returns a `DynamicSupervisor`, and RELEASE-008 explains why OTP release
  handling cannot inspect it. And the caller must admit the lane, which
  `relup_admitted: true` does. `OpenAgents.Forge.HotLoader` does not, because
  RELEASE-005 records that the relup workers stay disabled until isolated
  staging proves their provider and topology, and
  `OpenAgents.Forge.RelupDeployment.run/2` still has no production caller.
  Admitting the lane is therefore one named argument, not a flag search.
  """

  alias OpenAgents.Forge.RelupTopology

  @schema "openagents.deployment-lane.v1"
  @topology_schema "openagents.deployment-lane.topology.v1"
  @lanes ~w(direct relup rolling)

  # RELEASE-005's relup lane is "an application transition between any two
  # concrete X.Y.Z versions". In a build manifest that is exactly these
  # structural reasons and no others: the `.app` version moved, and with it the
  # `.app` spec digest that carries it. Any other reason — config, migrations,
  # dependencies, assets, ERTS, a deleted module — is structural in a way relup
  # does not describe, and belongs on rolling replacement regardless of
  # topology.
  @relup_shape ~w(toolchain_application_version_changed toolchain_application_spec_sha256_changed)

  # A classification is an operational record, not a dump. These bounds match
  # `OpenAgents.Forge.RelupTopology`'s so a verdict survives a bounded receipt
  # unchanged.
  @maximum_reasons 32
  @maximum_reason_bytes 128
  @maximum_entries 16

  @default_timeout 5_000

  @doc "Every lane a candidate can be classified for."
  def lanes, do: @lanes

  @doc """
  Choose the lane for one verified build manifest.

  Returns a bounded, content-free map carrying the chosen lane, the reasons
  that chose it, and the topology verdict the choice was made against. The
  verdict is recorded whether or not it was decisive, so a reader can tell a
  candidate that could never have taken the relup lane from one that was not
  eligible for it in the first place.

  Options:

    * `:offending` — module names the hot-load allowlist rejects.
    * `:topology` — the fleet verdict from `fleet_topology/1`. Absent means
      unread, which is treated as unsupported.
    * `:relup_admitted` — whether the caller can run the relup lane at all.
      Defaults to `false`; see the module documentation.
  """
  def classify(manifest, opts \\ []) when is_map(manifest) do
    topology = normalize_topology(Keyword.get(opts, :topology))
    offending = Keyword.get(opts, :offending, [])
    relup_admitted? = Keyword.get(opts, :relup_admitted, false)
    structural = structural_reasons(manifest)

    {lane, reasons} =
      cond do
        direct_candidate?(manifest, structural) and offending == [] ->
          {"direct", []}

        direct_candidate?(manifest, structural) ->
          {"rolling", Enum.map(offending, &"off_allowlist:#{&1}")}

        relup_shape?(structural) and relup_admitted? and topology["supported"] ->
          {"relup", structural}

        relup_shape?(structural) ->
          {"rolling", structural ++ relup_refusals(topology, relup_admitted?)}

        true ->
          {"rolling", structural}
      end

    %{
      "schema" => @schema,
      "lane" => lane,
      "reasons" => bound_reasons(reasons),
      "topology" => topology
    }
  end

  @doc """
  Read the relup topology verdict from every fleet member.

  Fails closed in every direction. A member that cannot be reached, that raises,
  or that answers with anything but a report counts as unreadable, and an empty
  member list is unread rather than unanimous. Only a fleet where every member
  answered and no member named an incompatible application supports relup.

  The verdict is content-free: it carries counts of nodes, never their names,
  and the application-to-supervisor entries `RelupTopology` already bounds.
  """
  def fleet_topology(opts \\ []) do
    nodes = members(opts)
    results = Enum.map(nodes, fn node -> node_report(node, opts) end)
    unreadable = Enum.count(results, &(&1 == :error))

    incompatible =
      results
      |> Enum.flat_map(fn
        {:ok, entries} -> entries
        :error -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@maximum_entries)

    %{
      "schema" => @topology_schema,
      "nodes" => length(nodes),
      "unreadable" => unreadable,
      "incompatible" => incompatible,
      "supported" => nodes != [] and unreadable == 0 and incompatible == []
    }
  end

  # ── classification ───────────────────────────────────────────────────────

  defp direct_candidate?(manifest, structural) do
    manifest["classification"] == "direct_candidate" and structural == []
  end

  defp relup_shape?([]), do: false
  defp relup_shape?(structural), do: Enum.all?(structural, &(&1 in @relup_shape))

  defp relup_refusals(topology, relup_admitted?) do
    admission = if relup_admitted?, do: [], else: ["relup_lane_unadmitted"]

    admission ++ topology_reasons(topology)
  end

  defp topology_reasons(%{"supported" => true}), do: []

  defp topology_reasons(topology) do
    unread = if topology["nodes"] == 0, do: ["topology_unread"], else: []
    unreadable = if topology["unreadable"] > 0, do: ["topology_unreadable"], else: []

    unread ++ unreadable ++ Enum.map(topology["incompatible"], &"topology_incompatible:#{&1}")
  end

  defp structural_reasons(manifest) do
    case manifest["structural_reasons"] do
      reasons when is_list(reasons) -> Enum.filter(reasons, &is_binary/1)
      _other -> []
    end
  end

  defp bound_reasons(reasons) do
    reasons
    |> Enum.map(&String.slice(&1, 0, @maximum_reason_bytes))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@maximum_reasons)
  end

  defp normalize_topology(%{} = topology) do
    %{
      "schema" => @topology_schema,
      "nodes" => integer(topology["nodes"]),
      "unreadable" => integer(topology["unreadable"]),
      "incompatible" => entries(topology["incompatible"]),
      "supported" => topology["supported"] == true
    }
  end

  defp normalize_topology(_absent) do
    %{
      "schema" => @topology_schema,
      "nodes" => 0,
      "unreadable" => 0,
      "incompatible" => [],
      "supported" => false
    }
  end

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0

  defp entries(value) when is_list(value) do
    value |> Enum.filter(&is_binary/1) |> Enum.take(@maximum_entries)
  end

  defp entries(_value), do: []

  # ── fleet read ───────────────────────────────────────────────────────────

  defp members(opts) do
    provider = Keyword.get(opts, :members, fn -> [Node.self() | Node.list()] end)
    provider.() |> Enum.uniq() |> Enum.sort()
  end

  defp node_report(node, opts) do
    reporter = Keyword.get(opts, :report, &default_report/2)

    case reporter.(node, opts) do
      {:ok, %{"incompatible" => entries}} when is_list(entries) ->
        {:ok, Enum.filter(entries, &is_binary/1)}

      _other ->
        :error
    end
  end

  defp default_report(node, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    try do
      if node == Node.self() do
        {:ok, RelupTopology.report([])}
      else
        {:ok, :erpc.call(node, RelupTopology, :report, [[]], timeout)}
      end
    rescue
      _error -> :error
    catch
      _kind, _reason -> :error
    end
  end
end
