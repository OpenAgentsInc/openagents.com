defmodule OpenAgentsWeb.OperatorSurfaceTest do
  @moduledoc """
  The executable enumeration behind ADMIN-001.

  ADMIN-001 used to be proven by tests of the `/admin` panel, so it stayed green
  while its own text was false: it said no routed controller returns recording
  audio, and `OpenAgentsWeb.AdminRecordingController` returned exactly that. A
  proof of one surface cannot establish a claim about every surface.

  So this file proves the claim's shape instead of its prose, in two directions,
  because operator authority is enforced in two places.

  Routes carry it when the `/admin` scope or an operator pipeline gates them,
  and `OpenAgentsWeb.RouteAuthority` already classifies those. Handlers carry it
  when the gate is inside the LiveView event or the controller action — forum
  moderation rides the channel of a route classified `:public_read`, and the
  forum API moderates behind the ordinary write pipeline — and no route table
  can see that. The second test reads each compiled module's import table for a
  call to `OpenAgents.Accounts.admin?/1`, which is where every one of those
  gates resolves.

  Both tables are exact sets. A new operator route or a new operator gate
  anywhere in `lib/` turns this red until ADMIN-001 names it.
  """

  use ExUnit.Case, async: true

  alias OpenAgentsWeb.RouteAuthority

  # Every route `OpenAgentsWeb.RouteAuthority` classifies `:operator`, as
  # {verb, path, scope, mutation?}. ADMIN-001 names each write; the reads are
  # the operator panels plus the recording reader.
  @operator_routes [
    # Reads.
    {"get", "/admin", "voice:metadata:read", false},
    {"get", "/admin/analytics", "analytics:read", false},
    {"get", "/admin/recordings", "voice:recording:list", false},
    {"get", "/admin/tokens", "tokens:productivity:read", false},
    {"get", "/chat", "chat:preview", false},
    {"get", "/api/v3/admin/forge/targets", "deployments:promote", false},
    {"get", "/api/v3/admin/forge/targets/:id", "deployments:promote", false},
    {"get", "/api/operator/artifact-listings/:id/export", "artifact-catalog:operate", false},
    {"get", "/api/operator/continual-learning/jobs", "continual-learning:operate", false},
    {"get", "/api/operator/continual-learning/jobs/:id", "continual-learning:operate", false},
    {"get", "/api/operator/continual-learning/jobs/:id/evidence", "continual-learning:operate",
     false},

    # The one route that hands one person another person's voice. It is a read,
    # it is unaudited, and ADMIN-001 says both.
    {"get", "/admin/recordings/:id/audio", "voice:recording:read", false},

    # Writes. Each of these appears by name in ADMIN-001.
    {"get", "/admin/forge", "forge:promote", true},
    {"get", "/admin/forum/claims", "forum:identity:link", true},
    {"get", "/admin/scv/accounts", "scv:account:connect", true},
    {"post", "/api/v3/admin/forge/targets", "deployments:promote", true},
    {"post", "/api/operator/agents/:handle/reinstate", "agents:moderate", true},
    {"post", "/api/operator/agents/:handle/suspend", "agents:moderate", true},
    {"post", "/api/operator/artifact-listings", "artifact-catalog:operate", true},
    {"delete", "/api/operator/artifact-listings/:id", "artifact-catalog:operate", true},
    {"post", "/api/operator/artifact-listings/:id/source-authorizations",
     "artifact-catalog:operate", true},
    {"post", "/api/operator/artifact-listings/:id/transactions/:action",
     "artifact-catalog:operate", true},
    {"post", "/api/operator/continual-learning/jobs", "continual-learning:operate", true},
    {"post", "/api/operator/continual-learning/jobs/:id/cancellation",
     "continual-learning:operate", true},
    {"post", "/api/operator/continual-learning/jobs/:id/replays", "continual-learning:operate",
     true},
    {"post", "/api/operator/continual-learning/jobs/:id/resumptions",
     "continual-learning:operate", true}
  ]

  # Every module in `lib/` that consults `OpenAgents.Accounts.admin?/1`, with
  # what the authority buys there.
  @operator_authority_modules %{
    OpenAgents.ApiTokens => "mints a privileged operator API token",
    OpenAgents.ContinualLearning => "gates job creation, cancellation, resumption, and replay",
    OpenAgents.Deployments.Authority => "separates the fleet operator from a tenant principal",
    OpenAgents.DeviceAuthorizations => "refuses to mint a device grant for an operator account",
    OpenAgents.Forge.Promotion => "gates fleet deploy-target promotion",
    OpenAgents.SCV.CodexAccounts => "gates connecting and disconnecting a Codex account",
    OpenAgents.SCV.Deployments => "gates starting an SCV deployment",
    OpenAgents.StagingCleanup => "refuses to delete an operator account",
    OpenAgents.Tools.ConversationExecutionContext => "selects the operator routing policy",
    OpenAgents.Tools.Reach => "satisfies the :operator reach requirement for a tool",
    OpenAgents.Transparency => "widens a repository's visible tier to :glass",
    OpenAgentsWeb.AdminAnalyticsLive => "rechecks the operator on mount and on every event",
    OpenAgentsWeb.AdminForgeLive => "rechecks the operator before promoting",
    OpenAgentsWeb.AdminLive => "rechecks the operator on mount and on every event",
    OpenAgentsWeb.AdminRecordingsLive => "rechecks the operator before listing recordings",
    OpenAgentsWeb.AdminScvAccountsLive => "rechecks the operator before connecting an account",
    OpenAgentsWeb.AdminTokensLive => "rechecks the operator on mount and on every event",
    OpenAgentsWeb.ForumApiController => "gates topic, post, and claim moderation over the API",
    OpenAgentsWeb.ForumBoardLive => "widens the board listing to private boards",
    OpenAgentsWeb.ForumTopicLive => "widens the topic read and gates closing and hiding",
    OpenAgentsWeb.HomeLive => "marks the session operator for the home surface",
    OpenAgentsWeb.Layouts => "shows the operator entries in the sidebar",
    OpenAgentsWeb.Plugs.OperatorApiTokenAuth => "rechecks the operator behind /api/operator",
    OpenAgentsWeb.ReputationController => "gates reputation subject-claim review over the API",
    OpenAgentsWeb.UserAuth => "gates the /admin scope as a plug and as an on_mount hook"
  }

  test "the operator-classified routes are exactly the set ADMIN-001 enumerates" do
    actual =
      RouteAuthority.inventory()
      |> Enum.filter(&(&1.class == :operator))
      |> MapSet.new(&{&1.verb, &1.path, &1.scope, &1.mutation})

    declared = MapSet.new(@operator_routes)

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           An operator route reached the router that ADMIN-001 does not name.
           Amend ADMIN-001 in INVARIANTS.md, then add it here.
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           ADMIN-001 names an operator route the router no longer serves.
           Amend ADMIN-001 in INVARIANTS.md, then remove it here.
           """
  end

  test "the recording reader is an operator route served by its named controller" do
    route =
      Phoenix.Router.route_info(
        OpenAgentsWeb.Router,
        "GET",
        "/admin/recordings/00000000-0000-4000-8000-000000000001/audio",
        "stage.openagents.com"
      )

    assert route.route == "/admin/recordings/:id/audio"
    assert route.plug == OpenAgentsWeb.AdminRecordingController
    assert route.plug_opts == :show
    assert route.pipe_through == [:browser, :authenticated, :operator]

    assert Enum.any?(
             RouteAuthority.inventory(),
             &(&1.path == "/admin/recordings/:id/audio" and &1.class == :operator)
           )
  end

  test "the modules that consult operator authority are exactly the set ADMIN-001 accounts for" do
    actual = MapSet.new(operator_authority_callers())
    declared = @operator_authority_modules |> Map.keys() |> MapSet.new()

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           A module gained operator authority without ADMIN-001 accounting for it.
           Amend ADMIN-001 in INVARIANTS.md, then add it here with what the
           authority buys there.
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           ADMIN-001 accounts for operator authority a module no longer consults.
           Amend ADMIN-001 in INVARIANTS.md, then remove it here.
           """
  end

  # Read from each compiled module's import table rather than from source text,
  # so a comment cannot add a caller and a rename cannot hide one.
  defp operator_authority_callers do
    {:ok, modules} = :application.get_key(:openagents, :modules)

    Enum.filter(modules, fn module ->
      with path when is_list(path) <- :code.which(module),
           {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
        {OpenAgents.Accounts, :admin?, 1} in imports
      else
        _unreadable -> false
      end
    end)
  end
end
