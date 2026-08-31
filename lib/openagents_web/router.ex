defmodule OpenAgentsWeb.Router do
  use OpenAgentsWeb, :router

  import OpenAgentsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpenAgentsWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "permissions-policy" => "microphone=(self)"
    }

    plug OpenAgentsWeb.Plugs.ContentSecurityPolicy

    plug OpenAgentsWeb.Plugs.PostHogBootstrap

    plug :fetch_current_user
    plug OpenAgentsWeb.Plugs.SidebarSections
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
  end

  pipeline :machine_controller_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.MachineTokenAuth
  end

  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_user
    plug :put_no_store
    plug :protect_from_forgery
    plug :require_authenticated_api_user
  end

  pipeline :forge_write_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.ApiTokenAuth, scope: "forge:write"
  end

  pipeline :agent_participation_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.DualPrincipalAuth, human_scope: "forge:write"
  end

  pipeline :agent_token_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.AgentTokenAuth, scope: "agent:participate"
  end

  pipeline :chat_account_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.ApiTokenAuth, scope: "chat:account"
  end

  # An anonymous lane that recognizes an account when one presents a credential
  # it can verify. It grants no authority and refuses nobody, so a route behind
  # it answers an anonymous caller exactly as it would without it.
  pipeline :ambient_account_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.AmbientApiTokenAuth, scope: "chat:account"
  end

  # OpenResponses surface. The client can ask for `text/event-stream`
  # (streaming) or `application/json` (non-streaming), so this pipeline does
  # not pin `accepts` to a single format.
  pipeline :openresponses_api do
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.AmbientApiTokenAuth, scope: "chat:account"
  end

  pipeline :box_control_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin

    plug OpenAgentsWeb.Plugs.AssignmentControlAuth,
      scope: "box:control",
      target_kind: "box"
  end

  pipeline :assignment_control_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.AssignmentControlAuth, scope: "box:control"
  end

  pipeline :assignment_computer_control_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin

    plug OpenAgentsWeb.Plugs.AssignmentControlAuth,
      scope: "computer:control",
      target_kind: "computer"
  end

  pipeline :computer_control_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin

    plug OpenAgentsWeb.Plugs.AssignmentControlAuth,
      scope: "computer:control",
      target_kind: "computer"
  end

  pipeline :human_computer_control_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.ApiTokenAuth, scope: "computer:control"
  end

  pipeline :delegation_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.DelegationAuth
  end

  # The deployment control plane authenticates two principals: a human holding
  # `deployments:write`, and a short-lived workflow grant. Neither carries the
  # operator-only fleet promotion authority.
  pipeline :deployments_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.DeploymentPrincipal
  end

  # Promoting the OpenAgents release itself is not a tenant action, so it has
  # a scope of its own that no ordinary account can hold, and operator standing
  # is rechecked on every request rather than trusted from issuance.
  pipeline :fleet_promotion_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.OperatorApiTokenAuth, scope: "deployments:promote"
  end

  pipeline :optional_forge_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.OptionalApiTokenAuth, scope: "forge:write"
  end

  pipeline :forge_git do
    plug OpenAgentsWeb.Plugs.ForgeGitAuth
  end

  # The agent front door answers one contract in two representations, Markdown
  # and JSON, so it cannot negotiate a single format. It reads no credential:
  # the document describes how to ask and grants nothing.
  pipeline :front_door do
    plug OpenAgentsWeb.Plugs.RequestOrigin
  end

  pipeline :status_probe_compat do
    plug OpenAgentsWeb.Plugs.StatusProbeCompat
  end

  pipeline :authenticated do
    plug :put_no_store
    plug :require_authenticated_user
  end

  pipeline :operator do
    plug :require_admin_user
  end

  pipeline :operator_api do
    plug :require_operator_api_user
  end

  scope "/", OpenAgentsWeb do
    pipe_through [:status_probe_compat, :browser]

    # Legacy forum paths resolve through OpenAgents.Forum and redirect to the
    # canonical topic route. Unknown ids answer 404; the mirror is never read.
    get "/forum/topic/:id", LegacyForumController, :topic
    get "/forum/post/:id", LegacyForumController, :post
    get "/changelog", LegacyChangelogController, :index

    live_session :public,
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/", HomeLive, :index
      live "/status", NetworkStatusLive, :index
      live "/leaderboard", LeaderboardLive, :index
      live "/coder", CoderLive, :index

      # Forum reads are public: the context's readability predicates decide
      # what an anonymous reader sees, and posting still requires an account.
      live "/forum", ForumHomeLive, :index
      live "/forum/f/:slug", ForumBoardLive, :show
      live "/forum/t/:id", ForumTopicLive, :show
    end

    # `/components/icons` must stay ahead of `/components/:slug` so the literal
    # route wins; the catalog's own slugs never include "icons".
    live_session :components,
      layout: {OpenAgentsWeb.Layouts, :components},
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/components", ComponentsLive, :index
      live "/components/icons", IconIndexLive, :index
      live "/components/:slug", ComponentsLive, :show
    end

    live_session :docs,
      layout: {OpenAgentsWeb.Layouts, :docs},
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/docs", DocsLive, :index
      live "/docs/:slug", DocsLive, :show
    end

    post "/auth/github", AuthController, :start
    get "/auth/github/callback", AuthController, :callback, log: false
    delete "/logout", AuthController, :logout
  end

  scope "/", OpenAgentsWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [{OpenAgentsWeb.UserAuth, :ensure_authenticated}] do
      live "/sarah", ChatLive, :index
      live "/memory", MemoryLive, :index
      live "/timeline", TimelineLive, :index
      live "/computers", ComputersLive, :index
      live "/artifact-catalog", ArtifactCatalogLive, :index
      live "/notifications", NotificationsLive, :index
      live "/settings/api-tokens", ApiTokensLive, :index
      # What each lane costs, before a thread spends against it. Same principal
      # as `GET /api/v1/models`, which the page renders (METER-001).
      live "/models", ModelCatalogLive, :index
      live "/threads", ThreadIndexLive, :index
      live "/threads/:id", ThreadShowLive, :show
      live "/device", DeviceAuthorizationLive, :show
      live "/repositories", RepositoryIndexLive, :index
      live "/repositories/new", RepositoryNewLive, :new
      live "/repositories/import/github", RepositoryImportLive, :new
      live "/github/connect", GitHubConnectLive, :show

      live "/forum/claim", ForumClaimLive, :new
      live "/forum/tips", ForumTipsLive, :show

      live "/:owner/:repo/issues/new", IssueNewLive, :new

      live "/:owner/:repo/members", MemberIndexLive, :index
      live "/:owner/:repo/assignees", AssigneeIndexLive, :index
    end

    post "/voice/calls", VoiceCallController, :create
    post "/voice/calls/interrupt", VoiceCallController, :interrupt
    post "/voice/telemetry", VoiceTelemetryController, :create
    post "/voice/calls/recording", VoiceRecordingController, :create
    post "/voice/calls/recording/complete", VoiceRecordingController, :complete
    delete "/voice/calls", VoiceCallController, :delete

    get "/data/export", DataController, :show
    get "/data/export/atif", DataController, :export_atif
    get "/data/export/account", DataController, :export_account
    delete "/data", DataController, :delete
    delete "/data/reset", DataController, :reset

    # The legacy Computers path is a permanent-ish redirect, not a second
    # render of the surface: it must drop its query (an OAuth `code=` must
    # never survive into the canonical URL).
    get "/machines", LegacyMachinesController, :show

    get "/memory/export", MemoryExportController, :show
    delete "/github/connection", AuthController, :disconnect
  end

  # The chat surface is a placeholder for the upcoming product, and it is
  # operator-only: the gate runs twice, as a plug on the initial request and as
  # an on_mount hook on the LiveView, the same belt-and-suspenders the /admin
  # scope uses. Everyone else is redirected to home rather than shown a login
  # wall for a page they cannot open.
  scope "/", OpenAgentsWeb do
    pipe_through [:browser, :authenticated, :operator]

    live_session :operator_chat,
      on_mount: [
        {OpenAgentsWeb.UserAuth, :ensure_authenticated},
        {OpenAgentsWeb.UserAuth, :ensure_admin}
      ] do
      live "/chat", ChatConsoleLive, :index

      # The Gym: graded benchmark runs of our agents
      # (docs/2026-08-24-harbor-terminal-bench-plan.md). Operator-only for
      # now — the whitelist is the operator allowlist, deliberately, rather
      # than a second gating mechanism. Widening it is a decision, not a
      # default.
      live "/gym", GymLive, :index
      live "/gym/runs/:id", GymRunLive, :show
    end
  end

  # These GitHub-style reads are public on a public repository, the way code
  # browsing already is, so this session runs behind plain :browser and mounts
  # whoever is signed in. Each view decides what an anonymous visitor may do,
  # and every write re-checks authority at the server. The scope comes after
  # the authenticated one so literal segments such as `new` keep winning over
  # repository-shaped routes.
  scope "/", OpenAgentsWeb do
    pipe_through :browser

    live_session :forge_issues,
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/issues", IssueWorkspaceLive, :index
      live "/projects", ProjectWorkspaceLive, :index
      live "/:owner/:repo/labels", LabelIndexLive, :index
      live "/:owner/:repo/milestones", MilestoneIndexLive, :index
      live "/:owner/:repo/projects/:number", ProjectShowLive, :show
      live "/:owner/:repo/projects", ProjectIndexLive, :index
      live "/:owner/:repo/pulls/:number", PullRequestShowLive, :show
      live "/:owner/:repo/pulls", PullRequestIndexLive, :index
      live "/:owner/:repo/issues/:number", IssueShowLive, :show
      live "/:owner/:repo/issues", IssueIndexLive, :index
    end
  end

  scope "/api", OpenAgentsWeb do
    pipe_through :authenticated_api

    get "/tokens", ApiTokenController, :index
    post "/tokens", ApiTokenController, :create
    delete "/tokens/:id", ApiTokenController, :delete

    get "/computers", ComputersController, :index
    get "/capacity", CapacityController, :show
    post "/computers/pairings/:id/approve", ComputersController, :approve_pairing
    delete "/computers/:id", ComputersController, :delete
    post "/computers/:computer_id/agent-jobs", ComputerAgentJobsController, :create
    get "/computer-agent-jobs/:id", ComputerAgentJobsController, :show
    delete "/computer-agent-jobs/:id", ComputerAgentJobsController, :delete

    get "/artifact-listings", ArtifactListingController, :index
    get "/artifact-listings/:id", ArtifactListingController, :show
    get "/artifact-listings/:id/export", ArtifactListingController, :export
  end

  scope "/api/operator", OpenAgentsWeb do
    pipe_through [:authenticated_api, :operator_api]

    post "/agents/:handle/suspend", AgentController, :suspend
    post "/agents/:handle/reinstate", AgentController, :reinstate

    post "/artifact-listings", ArtifactListingAdminController, :create
    delete "/artifact-listings/:id", ArtifactListingAdminController, :delete
    get "/artifact-listings/:id/export", ArtifactListingAdminController, :export
    post "/artifact-listings/:id/transactions/:action", ArtifactListingAdminController, :record

    post "/artifact-listings/:id/source-authorizations",
         ArtifactListingAdminController,
         :authorize

    post "/continual-learning/jobs", ContinualLearningController, :create
    get "/continual-learning/jobs", ContinualLearningController, :index
    get "/continual-learning/jobs/:id", ContinualLearningController, :show
    post "/continual-learning/jobs/:id/cancellation", ContinualLearningController, :cancel
    post "/continual-learning/jobs/:id/resumptions", ContinualLearningController, :resume
    post "/continual-learning/jobs/:id/replays", ContinualLearningController, :replay
    get "/continual-learning/jobs/:id/evidence", ContinualLearningController, :evidence
  end

  scope "/admin", OpenAgentsWeb do
    pipe_through [:browser, :authenticated, :operator]

    live_session :operator,
      on_mount: [
        {OpenAgentsWeb.UserAuth, :ensure_authenticated},
        {OpenAgentsWeb.UserAuth, :ensure_admin}
      ] do
      live "/", AdminLive, :index
      live "/analytics", AdminAnalyticsLive, :index
      live "/tokens", AdminTokensLive, :index
      live "/forge", AdminForgeLive, :index
      live "/recordings", AdminRecordingsLive, :index
      live "/scv/accounts", AdminScvAccountsLive, :index
      live "/forum/claims", AdminForumLinksLive, :index
    end

    get "/recordings/:id/audio", AdminRecordingController, :show
  end

  scope "/" do
    pipe_through :forge_git

    get "/:owner/:repo/info/refs", OpenAgents.Forge.GitHTTP, []
    post "/:owner/:repo/git-upload-pack", OpenAgents.Forge.GitHTTP, []
    post "/:owner/:repo/git-receive-pack", OpenAgents.Forge.GitHTTP, []
  end

  # Keep existing remotes operational while every newly issued clone URL uses
  # the canonical GitHub-shaped /:owner/:repo.git path.
  scope "/git" do
    pipe_through :forge_git
    forward "/", OpenAgents.Forge.GitHTTP
  end

  # Episode 230 put standing instructions for agents at `openagents.com/agents.md`.
  # The contract behind both representations is `OpenAgentsWeb.ContributionContract`.
  scope "/", OpenAgentsWeb do
    pipe_through :front_door

    get "/agents.md", AgentFrontDoorController, :markdown
    get "/agents.json", AgentFrontDoorController, :json
  end

  scope "/", OpenAgentsWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/healthz", HealthController, :show
    get "/api/status", NetworkStatusController, :show

    # The published WAL anchor (EXIT-005, ADR 0008). Anonymous by
    # construction: an anchor a reader must authenticate for is an anchor the
    # operator can withhold from the reader who would check it.
    get "/.well-known/openagents-forge-anchor.json", ForgeAnchorController, :show
    get "/api/changelog", ChangelogController, :show
    get "/api/contracts/repositories-v1.json", ApiContractController, :repositories_v1
    get "/api/contracts/do-not-build-v1.json", ApiContractController, :do_not_build_v1

    post "/controller/pairings", ControllerPairingController, :create
    get "/controller/pairings/:id", ControllerPairingController, :show
    post "/api/inference/proxy", InferenceProxyController, :create
  end

  scope "/", OpenAgentsWeb do
    pipe_through [:api, :machine_controller_api]

    get "/controller/status", ControllerPairingController, :status
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :api

    get "/", ApiExtensionController, :show

    get "/plugins", PluginRegistryController, :index
    get "/plugins/:name", PluginRegistryController, :show

    post "/device/authorizations", DeviceAuthorizationController, :create
    post "/device/authorizations/token", DeviceAuthorizationController, :token
  end

  # The ancillary issue metadata reads. They keep their position in the router
  # so nothing that used to match them matches something else now, and they run
  # behind the optional bearer so a member of a private repository can read the
  # comments, labels, milestones, and assignees of their own issues. An
  # anonymous caller reaches exactly the public repositories it reached before.
  scope "/api/v1", OpenAgentsWeb do
    pipe_through :optional_forge_api

    get "/repos/:owner/:repo/issues/:issue_number/comments", CommentController, :index
    get "/repos/:owner/:repo/issues/comments/:id", CommentController, :show
    get "/repos/:owner/:repo/issues/:issue_number/labels", IssueLabelController, :index
    get "/repos/:owner/:repo/issues/:issue_number/assignees", IssueAssigneeController, :index
    get "/repos/:owner/:repo/labels", LabelController, :index
    get "/repos/:owner/:repo/labels/:name", LabelController, :show
    get "/repos/:owner/:repo/milestones", MilestoneController, :index
    get "/repos/:owner/:repo/milestones/:milestone_number", MilestoneController, :show
    get "/repos/:owner/:repo/assignees", AssigneeController, :index
    get "/repos/:owner/:repo/assignees/:assignee", AssigneeController, :show

    # The push receipts the WAL recorded, so a pusher can re-read the chain
    # link `git push` printed to them. Read-only, and served from the WAL
    # rather than the derived rows, so this publishes what the verifier reads.
    get "/repos/:owner/:repo/pushes", PushReceiptController, :index
    get "/repos/:owner/:repo/pushes/:wal_seq", PushReceiptController, :show
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :deployments_api

    get "/repos/:owner/:repo/deployment-environments", DeploymentController, :environments

    put "/repos/:owner/:repo/deployment-environments/:name",
        DeploymentController,
        :put_environment

    get "/repos/:owner/:repo/deployment-environments/:name/protection",
        DeploymentController,
        :protection

    post "/repos/:owner/:repo/deployments", DeploymentController, :create
    get "/repos/:owner/:repo/deployments", DeploymentController, :index
    get "/repos/:owner/:repo/deployments/:id", DeploymentController, :show
    post "/repos/:owner/:repo/deployments/:id/cancel", DeploymentController, :cancel
    post "/repos/:owner/:repo/deployments/:id/approvals", DeploymentController, :decide
    get "/repos/:owner/:repo/deployments/:id/approvals", DeploymentController, :approvals
    get "/repos/:owner/:repo/deployments/:id/events", DeploymentController, :events
    post "/repos/:owner/:repo/deployment-checks", DeploymentController, :publish_check
    post "/repos/:owner/:repo/deployment-workflow-grants", DeploymentController, :issue_grant

    delete "/repos/:owner/:repo/deployment-workflow-grants/:id",
           DeploymentController,
           :revoke_grant
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :api

    post "/agents/register", AgentController, :register
  end

  # The OpenResponses surface. Anonymous callers are answered exactly as they
  # always were — the coder's dev lane reaches this route with no credential —
  # and a caller that does present a `chat:account` bearer is recognized so the
  # controller can recall that account's memories into the turn. The plug
  # grants nothing and refuses nobody; see
  # `OpenAgentsWeb.Plugs.AmbientApiTokenAuth`.
  scope "/api/v1", OpenAgentsWeb do
    pipe_through :openresponses_api

    post "/responses", ResponsesController, :create
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :agent_participation_api

    post "/forum/topics", ForumApiController, :create_topic
    post "/forum/topics/:topic_id/posts", ForumApiController, :create_post
    post "/repos/:owner/:repo/issues", IssueController, :create
    # Drafts, deduplicates, and files one problem statement (#77). It sits
    # beside :create rather than replacing it: :create is the GitHub-compatible
    # operation and takes a finished issue, this one takes a sentence.
    post "/repos/:owner/:repo/issues/capture", IssueController, :capture
    post "/repos/:owner/:repo/issues/:issue_number/comments", CommentController, :create

    post "/repos/:owner/:repo/issues/:issue_number/completion_claim",
         IssueCompletionClaimController,
         :create
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :forge_write_api

    post "/agents/:handle/box-control", AgentController, :grant_box_control
    delete "/agents/:handle/box-control", AgentController, :revoke_box_control
    post "/agents/:handle/computer-control", AgentController, :grant_computer_control
    delete "/agents/:handle/computer-control", AgentController, :revoke_computer_control

    # The Gym's ingest and read: an ordinary forge:write bearer carries the
    # request, and the controller rechecks live operator standing on every
    # call — the fleet-promotion shape without a privileged scope, because
    # recording a benchmark row moves no money and deploys nothing. The
    # lifecycle routes (start, trial upsert, finalize) share the exact same
    # posture.
    post "/gym/runs", GymRunController, :create
    post "/gym/runs/start", GymRunController, :start
    post "/gym/runs/:id/trials", GymRunController, :create_trial
    patch "/gym/runs/:id", GymRunController, :update
    get "/gym/runs", GymRunController, :index
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :delegation_api

    get "/conversations/:conversation_id/delegation-targets", DelegationsController, :targets
    post "/conversations/:conversation_id/delegations", DelegationsController, :create
    get "/conversations/:conversation_id/delegations/:id", DelegationsController, :show
    delete "/conversations/:conversation_id/delegations/:id", DelegationsController, :delete
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :computer_control_api

    get "/computers", ComputersController, :index
    post "/computers/:computer_id/probe", ComputersController, :probe
    post "/computers/:computer_id/agent-jobs", ComputerAgentJobsController, :create
    get "/computer-agent-jobs/:id", ComputerAgentJobsController, :show
    delete "/computer-agent-jobs/:id", ComputerAgentJobsController, :delete
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :human_computer_control_api

    patch "/computers/:id", ComputersController, :update
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :forge_write_api

    get "/agents/links", AgentController, :links
    post "/agents/links/:id/accept", AgentController, :accept_link
    post "/agents/links/:id/reject", AgentController, :reject_link
    delete "/agents/links/:id", AgentController, :unlink
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :agent_token_api

    get "/agent", AgentController, :current
    post "/agent/credentials", AgentController, :rotate_credential
    post "/agent/links", AgentController, :request_link
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :api

    get "/agents/:handle", AgentController, :show
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :chat_account_api

    get "/coder/identity", CoderIdentityController, :show
    post "/coder/token", CoderTokenController, :create
    post "/coder/grant", CoderGrantController, :create
    get "/chat/events", ChatTurnController, :index
    post "/chat/turns", ChatTurnController, :create
    get "/capacity", CapacityController, :show
    post "/capacity/matches", CapacityController, :matches
  end

  # Memories: what the account asked to have remembered. The write path only —
  # recall runs server-side inside `POST /api/v1/responses`, so no client
  # implements retrieval. The account scope, because a memory belongs to an
  # account rather than to a repository or a thread.
  scope "/api/v1", OpenAgentsWeb do
    pipe_through :chat_account_api

    post "/memories", MemoryController, :create
    get "/memories", MemoryController, :index
    delete "/memories/:id", MemoryController, :delete
  end

  # Threads: the unit of agent work, and the model authority bound to one. The
  # same account scope as the chat lane, because a thread is what that lane's
  # single conversation could not be — plural, disposable, and fenced on its
  # own (THREAD-001).
  scope "/api/v1", OpenAgentsWeb do
    pipe_through :chat_account_api

    # The typed model catalog the thread admission checks against. It sits in
    # the thread scope because it names what a thread grant can be minted for.
    get "/models", ModelCatalogController, :index

    # What a thread is minted against. Same scope for the same reason: the
    # caller who can open a thread is the caller who reads what is left to
    # open one with.
    get "/credit", CreditController, :show

    post "/threads", ThreadController, :create
    post "/traces", TraceController, :create
    get "/threads", ThreadController, :index
    get "/threads/:thread_id", ThreadController, :show
    delete "/threads/:thread_id", ThreadController, :delete
    post "/threads/:thread_id/report", ThreadController, :report
    get "/threads/:thread_id/events", ThreadController, :events
    post "/threads/:thread_id/events", ThreadController, :record
    post "/threads/:thread_id/grants", ThreadController, :mint
  end

  # The bootstrap read for a box client: it needs a conversation id before it
  # can address any box route, and this is the only conversation read a
  # `box:control` token can reach.
  scope "/api/v1", OpenAgentsWeb do
    pipe_through :box_control_api

    get "/conversation", ConversationController, :show
  end

  scope "/api/v1/conversations/:conversation_id/boxes", OpenAgentsWeb do
    pipe_through :box_control_api

    get "/", BoxController, :index
    post "/", BoxController, :create
    post "/fanout", BoxFanoutController, :create
    get "/fanout/:request_id", BoxFanoutController, :show
    get "/:box_id", BoxController, :show
    post "/:box_id/commands", BoxController, :command
    post "/:box_id/stop", BoxController, :stop
    post "/:box_id/runs", BoxRunController, :create
    get "/:box_id/runs", BoxRunController, :index
    get "/:box_id/runs/:run_id", BoxRunController, :show
    get "/:box_id/runs/:run_id/output", BoxRunController, :output
    post "/:box_id/runs/:run_id/cancel", BoxRunController, :cancel
  end

  scope "/api/v1/conversations/:conversation_id/computers", OpenAgentsWeb do
    pipe_through :assignment_computer_control_api

    post "/:computer_id/assignments", AssignmentController, :create
    get "/:computer_id/assignments/:assignment_id", AssignmentController, :show
    post "/:computer_id/assignments/:assignment_id/cancel", AssignmentController, :cancel
  end

  scope "/api/v1/conversations/:conversation_id/boxes", OpenAgentsWeb do
    pipe_through :assignment_control_api

    post "/:box_id/assignments", AssignmentController, :create
    get "/:box_id/assignments/:assignment_id", AssignmentController, :show
    post "/:box_id/assignments/:assignment_id/cancel", AssignmentController, :cancel
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :forge_write_api

    post "/forum/claims", ForumApiController, :create_claim
    get "/forum/claims", ForumApiController, :list_claims

    # Reputation subject claims. An attestation names its subject with a bare
    # string, so an account establishes which strings are its own the way it
    # claims a legacy forum identity: it asks, and an operator decides.
    post "/reputation/subject-claims", ReputationController, :create_subject_claim
    get "/reputation/subject-claims", ReputationController, :list_subject_claims

    # Claim review. The controller refuses a non-operator token.
    get "/reputation/subject-claims/pending", ReputationController, :pending_subject_claims
    patch "/reputation/subject-claims/:id", ReputationController, :update_subject_claim

    # Moderation and claim review. The controller refuses a non-operator token.
    get "/forum/claims/pending", ForumApiController, :pending_claims
    patch "/forum/claims/:id", ForumApiController, :update_claim
    patch "/forum/topics/:id", ForumApiController, :update_topic
    patch "/forum/posts/:id", ForumApiController, :update_post

    # Tips. A destination and a settlement history belong to one account, so
    # every tip route requires that account's own token.
    post "/forum/tips/destination", ForumApiController, :put_tip_destination
    patch "/forum/tips/destination", ForumApiController, :update_tip_destination
    get "/forum/tips/destination", ForumApiController, :show_tip_destination
    get "/forum/tips/received", ForumApiController, :list_received_tips
    post "/forum/posts/:post_id/tips", ForumApiController, :create_tip
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :optional_forge_api

    get "/repos/:owner/:repo", RepositoryController, :show
    get "/repos/:owner/:repo/issues", IssueController, :index
    get "/repos/:owner/:repo/issues/:issue_number", IssueController, :show

    get "/repos/:owner/:repo/issues/:issue_number/activity",
        IssueController,
        :activity

    get "/repos/:owner/:repo/issues/:issue_number/dependencies",
        IssueDependencyController,
        :index

    get "/repos/:owner/:repo/pulls", PullRequestController, :index
    get "/repos/:owner/:repo/pulls/:pull_number", PullRequestController, :show

    get "/repos/:owner/:repo/pulls/:pull_number/merge-async/:operation_id",
        StackController,
        :merge_async_status

    get "/repos/:owner/:repo/stacks", StackController, :index
    get "/repos/:owner/:repo/stacks/:stack_number", StackController, :show

    get "/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id",
        StackController,
        :show_operation

    get "/repos/:owner/:repo/projectsV2", ProjectController, :index
    get "/repos/:owner/:repo/projectsV2/:project_number", ProjectController, :show
    get "/repos/:owner/:repo/projectsV2/:project_number/items", ProjectController, :items

    get "/repos/:owner/:repo/projectsV2/:project_number/items/:item_id/events",
        ProjectController,
        :events

    get "/repos/:owner/:repo/projectsV2/:project_number/fields", ProjectController, :fields
    get "/repos/:owner/:repo/projectsV2/:project_number/notes", ProjectController, :notes

    # Reputation attestations. Reads only: issuance and revocation stay behind
    # verifier authority inside the application.
    get "/reputation/policy", ReputationController, :policy
    get "/reputation/keys", ReputationController, :keys

    get "/repos/:owner/:repo/issues/:issue_number/attestations",
        ReputationController,
        :index

    get "/repos/:owner/:repo/attestations/:id", ReputationController, :show

    get "/repos/:owner/:repo/attestations/:id/verification",
        ReputationController,
        :verification

    get "/repos/:owner/:repo/reputation/subjects/:subject_id", ReputationController, :subject

    # The forum reads. Posting and claiming live behind the write scope.
    get "/forum", ForumApiController, :boards
    get "/forum/topics", ForumApiController, :topics
    get "/forum/topics/:id", ForumApiController, :show_topic
  end

  scope "/api/v1/admin/forge", OpenAgentsWeb do
    pipe_through :fleet_promotion_api

    post "/targets", FleetTargetController, :create
    get "/targets", FleetTargetController, :index
    get "/targets/:id", FleetTargetController, :show
  end

  scope "/api/v1", OpenAgentsWeb do
    pipe_through :forge_write_api

    get "/user", ForgeUserController, :show
    get "/user/repos", RepositoryController, :index
    post "/repos", RepositoryController, :create
    post "/user/repos", RepositoryController, :create_user
    post "/orgs/:org/repos", RepositoryController, :create_organization
    delete "/repos/:owner/:repo", RepositoryController, :delete
    patch "/repos/:owner/:repo", RepositoryController, :update
    post "/user/repos/imports", RepositoryImportController, :create_user
    post "/orgs/:org/repos/imports", RepositoryImportController, :create_organization
    get "/repository-imports/:id", RepositoryImportController, :show

    put "/repos/:owner/:repo/issues/:issue_number", IssueController, :update
    patch "/repos/:owner/:repo/issues/:issue_number", IssueController, :update
    post "/repos/:owner/:repo/pulls", PullRequestController, :create
    patch "/repos/:owner/:repo/pulls/:pull_number", PullRequestController, :update
    put "/repos/:owner/:repo/pulls/:pull_number/merge-async", StackController, :merge_async
    post "/repos/:owner/:repo/stacks", StackController, :create
    post "/repos/:owner/:repo/stacks/:stack_number/append", StackController, :append
    post "/repos/:owner/:repo/stacks/:stack_number/unstack", StackController, :unstack
    post "/repos/:owner/:repo/stacks/:stack_number/dissolve", StackController, :dissolve
    post "/repos/:owner/:repo/stacks/:stack_number/rebase", StackController, :rebase
    post "/repos/:owner/:repo/stacks/:stack_number/merge", StackController, :merge

    post "/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id/continue",
         StackController,
         :continue_operation

    post "/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id/abort",
         StackController,
         :abort_operation

    put "/repos/:owner/:repo/issues/comments/:id", CommentController, :update
    patch "/repos/:owner/:repo/issues/comments/:id", CommentController, :update
    delete "/repos/:owner/:repo/issues/comments/:id", CommentController, :delete

    post "/repos/:owner/:repo/issues/:issue_number/dependencies",
         IssueDependencyController,
         :create

    delete "/repos/:owner/:repo/issues/:issue_number/dependencies/:blocked_by_number",
           IssueDependencyController,
           :delete

    post "/repos/:owner/:repo/issues/:issue_number/labels", IssueLabelController, :create
    delete "/repos/:owner/:repo/issues/:issue_number/labels/:name", IssueLabelController, :delete
    post "/repos/:owner/:repo/issues/:issue_number/assignees", IssueAssigneeController, :create
    delete "/repos/:owner/:repo/issues/:issue_number/assignees", IssueAssigneeController, :delete
    post "/repos/:owner/:repo/labels", LabelController, :create
    put "/repos/:owner/:repo/labels/:name", LabelController, :update
    patch "/repos/:owner/:repo/labels/:name", LabelController, :update
    delete "/repos/:owner/:repo/labels/:name", LabelController, :delete
    post "/repos/:owner/:repo/milestones", MilestoneController, :create
    put "/repos/:owner/:repo/milestones/:milestone_number", MilestoneController, :update
    patch "/repos/:owner/:repo/milestones/:milestone_number", MilestoneController, :update
    delete "/repos/:owner/:repo/milestones/:milestone_number", MilestoneController, :delete
    post "/repos/:owner/:repo/projectsV2", ProjectController, :create

    post "/repos/:owner/:repo/projectsV2/:project_number/items",
         ProjectController,
         :create_item

    post "/repos/:owner/:repo/projectsV2/:project_number/fields",
         ProjectController,
         :create_field

    patch "/repos/:owner/:repo/projectsV2/:project_number/items/:item_id",
          ProjectController,
          :update_item

    post "/repos/:owner/:repo/projectsV2/:project_number/items/:item_id/move",
         ProjectController,
         :move_item

    delete "/repos/:owner/:repo/projectsV2/:project_number/items/:item_id",
           ProjectController,
           :delete_item

    patch "/repos/:owner/:repo/projectsV2/:project_number", ProjectController, :update

    post "/repos/:owner/:repo/projectsV2/:project_number/notes",
         ProjectController,
         :create_note

    patch "/repos/:owner/:repo/projectsV2/:project_number/notes/:note_id",
          ProjectController,
          :update_note

    delete "/repos/:owner/:repo/projectsV2/:project_number/notes/:note_id",
           ProjectController,
           :delete_note

    patch "/repos/:owner/:repo/projectsV2/:project_number/fields/:field_id",
          ProjectController,
          :update_field

    delete "/repos/:owner/:repo/projectsV2/:project_number/fields/:field_id",
           ProjectController,
           :delete_field

    delete "/repos/:owner/:repo/projectsV2/:project_number", ProjectController, :delete
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:openagents, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OpenAgentsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Open Graph card images: content-versioned, HMAC-signed, public-only.
  # The version segment is advisory cache-busting; the signature gates the
  # endpoint against third-party rendering abuse; private and missing
  # repositories are indistinguishable 404s.
  scope "/og", OpenAgentsWeb do
    get "/static/card.png", OgImageController, :static
    get "/v/:version/repos/:owner/:repo", OgImageController, :repo
    get "/v/:version/repos/:owner/:repo/issues/:number", OgImageController, :issue
    get "/v/:version/repos/:owner/:repo/pulls/:number", OgImageController, :pull
    get "/v/:version/repos/:owner/:repo/commit/:sha", OgImageController, :commit
    get "/v/:version/repos/:owner/:repo/blob/:ref/*path", OgImageController, :blob
    get "/v/:version/docs/:slug", OgImageController, :docs
    get "/v/:version/forum/f/:slug", OgImageController, :forum_board
    get "/v/:version/forum/t/:id", OgImageController, :forum_topic
  end

  # CLI release downloads. No pipeline: `:browser` accepts only HTML and would
  # refuse an installer asking for `application/octet-stream`, while `:api`
  # accepts only JSON and would refuse a browser. The route is public by
  # construction — it proxies a world-readable bucket — so there is no session
  # or bearer for a pipeline to establish.
  #
  # One segment, not `/*path`. The bucket is flat, so a deeper path names no
  # object; and `releases` is a reserved slug, which already gives every deeper
  # path a `NotFoundController` route below. A glob here would shadow that
  # route entirely and the compiler would say so.
  scope "/releases", OpenAgentsWeb do
    get "/:name", ReleaseController, :show
  end

  # Keep repository-shaped routes last. Every fixed product, API, operator,
  # Git, and development route above wins before a GitHub-backed namespace can
  # be interpreted from the first path segment.
  scope "/", OpenAgentsWeb do
    pipe_through :browser

    for reserved <- OpenAgents.Repositories.Namespace.reserved_slugs() do
      get "/#{reserved}/*path", NotFoundController, :show
    end
  end

  scope "/", OpenAgentsWeb do
    pipe_through :browser

    live_session :repository_code,
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/:owner/:repo", CodeRepoLive, :index
      live "/:owner/:repo/commit/:sha", CodeCommitLive, :index
      live "/:owner/:repo/tree/:ref/*path", CodeTreeLive, :index
      live "/:owner/:repo/blob/:ref/*path", CodeBlobLive, :index
    end
  end
end
