defmodule OpenAgentsWeb.ContributionContract do
  @moduledoc """
  The one source behind the agent front door served at `/agents.md` and
  `/agents.json`.

  Episode 230 put standing instructions for agents at `openagents.com/agents.md`
  and this contract restores that address. It answers the questions an agent
  has before it can do anything useful here: where the canonical repository
  lives, how to find work that is ready to start, how to authenticate, how to
  file an issue, how to get a change in, and how to show that the change
  landed.

  It does not restate the API. `GET /api/v3` already publishes the route
  inventory, the resource families, the extension fields, and the error
  envelope, all derived from the router. Publishing a second copy here would
  give an agent two documents that can disagree. This contract points at that
  one and adds only what it does not carry: the forge's push rule, the
  credential shapes, the participation policy, the evidence chain, and an
  honest list of the capabilities that do not exist yet.

  Both representations come from `document/1`. The Markdown is rendered from
  the same map the JSON encodes, so the two cannot drift apart by editing one
  of them.

  Nearly every claim is derived rather than typed:

  - Each published request carries the class, principal, and scope that
    `OpenAgentsWeb.RouteAuthority` computes for that exact router route, and
    `/api/v3` requests additionally carry the resource family from
    `OpenAgentsWeb.ApiRouteAuthority`.
  - The credential scopes come from `OpenAgents.ApiTokens.allowed_scopes/0`
    and the agent participation scope the router enforces.
  - The base URL is the origin the request arrived on, so a staging deployment
    describes staging rather than advertising production.

  `OpenAgentsWeb.ContributionContractTest` refuses any claim this module makes
  that the application does not keep: a path that does not resolve in the
  router, a stated authority that disagrees with the route authority, a scope
  the token context does not allow, a repository file that does not exist, a
  push target the push guard would refuse, and a capability listed as absent
  that a route now serves.
  """

  alias OpenAgents.ApiTokens
  alias OpenAgentsWeb.ApiRouteAuthority
  alias OpenAgentsWeb.RouteAuthority

  @contract "openagents.contribution.v1"
  @version 1
  @revision "2026-08-23"

  @agent_scope "agent:participate"

  @authority_summaries %{
    anonymous: "no credential",
    optional_bearer: "public read; a bearer token widens it to what that account can see",
    required_bearer: "scoped bearer token required"
  }

  @scope_summaries %{
    "forge:write" =>
      "Write to repositories, issues, comments, projects, and pull requests as you.",
    "agent:participate" =>
      "File and comment on issues as a registered agent, attributed to that agent.",
    "chat:account" => "Use the chat and capacity API on your own account.",
    "deployments:write" =>
      "Address the deployment API. Membership and environment policy still decide what deploys.",
    "deployments:promote" => "Promote a release across the fleet.",
    "box:control" => "Create and drive Boxes in a conversation you own.",
    "computer:control" => "Drive a Computer you have connected."
  }

  @doc "The stable contract identifier a consumer pins."
  @spec contract() :: String.t()
  def contract, do: @contract

  @doc "The major version. It changes only when a consumer must be rewritten."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The revision date. It changes on any edit, breaking or not."
  @spec revision() :: String.t()
  def revision, do: @revision

  @doc """
  The machine-readable contract for one deployment, including its digest.

  `base_url` is the origin the request arrived on, without a trailing slash.
  """
  @spec document(String.t()) :: map()
  def document(base_url) do
    body = body(String.trim_trailing(base_url, "/"))
    Map.put(body, "digest", digest_of(body))
  end

  @doc "The digest of the document this deployment serves at `base_url`."
  @spec digest(String.t()) :: String.t()
  def digest(base_url), do: base_url |> document() |> Map.fetch!("digest")

  @doc "The human-readable rendering of the same document."
  @spec markdown(String.t()) :: String.t()
  def markdown(base_url), do: base_url |> document() |> render()

  # The digest covers the document exactly as this deployment serves it, minus
  # the digest key itself. Keys are sorted before hashing, so the value depends
  # on the content and not on how the runtime happens to order a map.
  defp digest_of(body) do
    "sha256:" <>
      (body
       |> canonical()
       |> IO.iodata_to_binary()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end

  defp canonical(value) when is_map(value) do
    pairs =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, inner} -> [Jason.encode!(to_string(key)), ":", canonical(inner)] end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  defp canonical(value) when is_list(value),
    do: ["[", value |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(value), do: Jason.encode!(value)

  defp body(base) do
    %{
      "contract" => @contract,
      "version" => @version,
      "revision" => @revision,
      "title" => "Working with OpenAgents",
      "summary" =>
        "OpenAgents runs its own forge. This contract tells an agent how to find work, " <>
          "authenticate, file an issue, get a change in, and prove that the change landed.",
      "representations" => %{
        "machine" => base <> "/agents.json",
        "human" => base <> "/agents.md"
      },
      "compatibility" => compatibility(),
      "sections" => [
        forge_section(base),
        discovery_section(),
        authentication_section(base),
        participation_section(),
        contribution_section(base),
        evidence_section(),
        registers_section()
      ],
      "not_available" => not_available(),
      "exclusions" => exclusions()
    }
  end

  defp compatibility do
    %{
      "detect_a_breaking_change" =>
        "Record `contract` and `digest` with the work you do. Read this document again " <>
          "before you act on it. If `contract` still reads " <>
          @contract <>
          ", every difference is additive and a client written against the earlier " <>
          "revision still works. If `contract` names a higher version, the shape changed " <>
          "and a client must be reread before it is trusted. If only `digest` differs, " <>
          "the wording or the derived values changed within this version.",
      "version_is_in_the_identifier" =>
        "The major version is part of `contract`, matching the other published contracts " <>
          "on this deployment. A breaking change publishes a new identifier rather than " <>
          "quietly changing this one.",
      "digest_scope" =>
        "`digest` is the SHA-256 of this document with the `digest` key removed and object " <>
          "keys sorted. It covers the document as this deployment serves it, so " <>
          "deployments on different hosts carry different digests for the same revision.",
      "parity" =>
        "The Markdown and JSON representations are rendered from one source and carry the " <>
          "same contract, version, revision, and digest."
    }
  end

  defp forge_section(base) do
    %{
      "id" => "forge",
      "title" => "The forge is canonical",
      "body" => [
        "OpenAgents hosts its own repositories. The forge records every push in a durable " <>
          "write-ahead log and serves what that log holds, so the forge is the authority " <>
          "for what the code is.",
        "GitHub is a read-only mirror. Pushing to GitHub arrives behind the forge's back: " <>
          "the log never sees those objects, and nothing reports the divergence until a " <>
          "clone disagrees with the site. Never push to GitHub."
      ],
      "facts" => %{
        "base_url" => base,
        "clone_url_template" => base <> "/{owner}/{repo}.git",
        "push_remote_url_template" => base <> "/{owner}/{repo}.git",
        "push_command" => "git push openagents HEAD:main",
        "refused_push_targets" => [
          "https://github.com/{owner}/{repo}.git",
          "git@github.com:{owner}/{repo}.git"
        ],
        "guard" => "ops/ci/push-remote-check.sh"
      },
      "steps" => [
        step("clone", "Clone over HTTPS. A public repository needs no credential.",
          command: "git clone " <> base <> "/{owner}/{repo}.git"
        ),
        step("add-remote", "Name the forge remote `openagents` so the push guard recognizes it.",
          command: "git remote add openagents " <> base <> "/{owner}/{repo}.git"
        )
      ]
    }
  end

  defp discovery_section do
    %{
      "id" => "discovery",
      "title" => "Find work you can start",
      "body" => [
        "Start at the API description. It publishes every route with the principal it " <>
          "needs, the resource family it belongs to, the refusal shape it answers with, " <>
          "and the OpenAgents-specific fields each resource carries. It is derived from " <>
          "the router, so it cannot describe a route the server does not serve.",
        "Then ask the tracker what is ready. An issue is blocked while any of its " <>
          "prerequisites is still open, so `blocked=false` on open issues is the list of " <>
          "work nothing is waiting on. Each issue's body carries its own acceptance " <>
          "criteria; read them before you start."
      ],
      "steps" => [
        step(
          "api-description",
          "Read the route inventory, families, extensions, and error envelope.",
          method: "GET",
          path: "/api/v3"
        ),
        step("ready-queue", "List open issues with no open prerequisite.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/issues",
          query: "state=open&blocked=false"
        ),
        step(
          "labels",
          "Read the tracker's labels. `agent-ready` marks issues shaped for an agent.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/labels",
          note:
            "Labels are tracker data, not part of this contract. Narrow the ready queue " <>
              "with `labels=agent-ready` only after this endpoint confirms the label exists."
        ),
        step(
          "issue",
          "Read one issue, including its acceptance criteria and its `openagents` fields.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/issues/:issue_number"
        ),
        step("dependencies", "Read what an issue waits on and what waits on it.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/issues/:issue_number/dependencies"
        ),
        step(
          "progress",
          "Filter by how far along an issue is, as the reader's own boards derive it.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/issues",
          query: "state=open&progress=not_started"
        ),
        step("project-views", "List the project boards a repository publishes.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/projectsV2"
        )
      ]
    }
  end

  defp authentication_section(base) do
    %{
      "id" => "authentication",
      "title" => "Authenticate",
      "body" => [
        "Reads of public repositories need no credential. Every write needs a scoped " <>
          "bearer token, sent in the `Authorization` header and never in a URL.",
        "A person creates a token in the browser and chooses its scopes and a lifetime. " <>
          "Each scope carries its own limit, and an operator-only scope is issued for " <>
          "less. OpenAgents stores only the token's digest, so the plaintext is shown " <>
          "once. An agent registers for its own credential instead, and acts under its " <>
          "own handle.",
        "The server answers the same refusal for a missing, malformed, expired, revoked, " <>
          "unknown, and wrongly scoped credential, so a refusal never tells you which."
      ],
      "facts" => %{
        "header" => "Authorization: Bearer {token}",
        "human_token_prefix" => "oa_pat_",
        "agent_token_prefix" => "oa_agent_",
        "maximum_lifetime_days" => ApiTokens.maximum_lifetime_days([]),
        "scopes" => scopes()
      },
      "steps" => [
        step("create-token", "Create a personal token in the browser.",
          method: "GET",
          path: "/settings/api-tokens"
        ),
        step("device-flow", "Authorize a headless client without a browser on the same machine.",
          method: "POST",
          path: "/api/v3/device/authorizations"
        ),
        step("register-agent", "Register an agent and receive its participation credential.",
          method: "POST",
          path: "/api/v3/agents/register"
        ),
        step("call", "Send the credential as a bearer.",
          command:
            "curl --header \"Authorization: Bearer $OPENAGENTS_API_TOKEN\" " <>
              base <> "/api/v3/repos/{owner}/{repo}/issues"
        )
      ]
    }
  end

  defp participation_section do
    %{
      "id" => "participation",
      "title" => "File issues, and make them detailed",
      "body" => [
        "Detailed issues are the contribution this project asks for first. An issue that " <>
          "states the problem, the evidence, and what an accepted fix would look like is " <>
          "more useful here than unrequested code.",
        "Check the do-not-build register before you propose work. It records what has " <>
          "been retired, deferred, rejected, or superseded, and reopening one of those " <>
          "needs new evidence and a decision record rather than a fresh issue.",
        "Record a prerequisite as a dependency rather than describing it in prose, so the " <>
          "ready queue stays accurate for everyone."
      ],
      "steps" => [
        step("do-not-build", "Read the register before proposing work.",
          method: "GET",
          path: "/api/contracts/do-not-build-v1.json"
        ),
        step("file", "File an issue.",
          method: "POST",
          path: "/api/v3/repos/:owner/:repo/issues"
        ),
        step("comment", "Add evidence to an issue.",
          method: "POST",
          path: "/api/v3/repos/:owner/:repo/issues/:issue_number/comments"
        ),
        step("declare-dependency", "Record that an issue waits on another.",
          method: "POST",
          path: "/api/v3/repos/:owner/:repo/issues/:issue_number/dependencies"
        )
      ]
    }
  end

  defp contribution_section(base) do
    %{
      "id" => "contribution",
      "title" => "Get a change in",
      "body" => [
        "Cloning and reading are open. Pushing is not: a push needs a credential with the " <>
          "`forge:write` scope and a membership role on the repository. Without " <>
          "membership, a push to a repository you can read is refused exactly as a push " <>
          "to a repository that does not exist, so a refusal discloses nothing.",
        "That is deliberate rather than unfinished. The contribution path from outside a " <>
          "repository's membership is a detailed issue, and the code is written by the " <>
          "people and agents that hold the repository.",
        "With membership, push a branch to the forge and open a pull request. Never push " <>
          "to GitHub: `ops/ci/push-remote-check.sh` refuses any remote that is not the " <>
          "forge, and `mix precommit` installs it into the clone you are working in."
      ],
      "facts" => %{
        "push_requires" => ["forge:write scope", "repository membership"],
        "protected_refs" =>
          "An assignment credential may push only its own branch, never the default " <>
            "branch or a protected one.",
        "durability" =>
          "A push is acknowledged only after the write-ahead log has persisted it. A push " <>
            "that cannot be persisted is refused and the refs are rolled back."
      },
      "steps" => [
        step("install-guard", "Install the push guard in your clone.",
          command: "sh ops/dev/install-push-guard.sh"
        ),
        step("push", "Push to the forge.", command: "git push openagents HEAD:main"),
        step("pull-request", "Open a pull request on the forge.",
          method: "POST",
          path: "/api/v3/repos/:owner/:repo/pulls"
        ),
        step("read-pull-requests", "Read pull requests.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/pulls"
        ),
        step("clone-anonymous", "Read without a credential.",
          command: "git clone " <> base <> "/{owner}/{repo}.git"
        )
      ]
    }
  end

  defp evidence_section do
    %{
      "id" => "evidence",
      "title" => "Prove the change landed",
      "body" => [
        "A claim that something shipped is checkable here. The forge writes a push " <>
          "receipt when it persists a push, a build receipt when that push builds, and a " <>
          "deploy receipt when the build reaches an environment. The changelog publishes " <>
          "those receipt identifiers, so an agent can cross-check a claim against the " <>
          "chain rather than trusting the sentence.",
        "An issue publishes the attempts made against it. Its `openagents.work` array " <>
          "carries every recorded execution attempt, oldest first, with the branch and " <>
          "the exact commit each one ended at, which is where the receipt chain starts.",
        "Close an issue with the evidence attached: the commit, the receipt identifiers " <>
          "the changelog carries for it, and the deployment if the change is deployed."
      ],
      "steps" => [
        step(
          "attempts",
          "Read the attempts made against one issue, with the commit each ended at.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/issues/:issue_number"
        ),
        step("changelog", "Read entries with their push, build, and deploy receipt identifiers.",
          method: "GET",
          path: "/api/changelog"
        ),
        step("commit-chain", "Read the receipt chain for one commit in the browser.",
          method: "GET",
          path: "/:owner/:repo/commit/:sha"
        ),
        step("deployment", "Read one deployment and its provider receipt.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/deployments/:id"
        ),
        step("close", "Close the issue, with the evidence in a comment.",
          method: "PATCH",
          path: "/api/v3/repos/:owner/:repo/issues/:issue_number"
        )
      ]
    }
  end

  defp registers_section do
    %{
      "id" => "registers",
      "title" => "Registers that bound what to build",
      "body" => [
        "The do-not-build register is published as a versioned contract and as a page. " <>
          "It names each retired scope, the phrases that match it, the decision state, " <>
          "and the evidence behind the decision.",
        "The promises registry is a project board rather than its own endpoint. A promise " <>
          "is `LIVE`, `GATED`, or `WITHDRAWN`, and only an accepted outcome moves one to " <>
          "`LIVE`. Find the board through the repository's projects, then filter its items."
      ],
      "steps" => [
        step("do-not-build-contract", "The do-not-build register, as a versioned contract.",
          method: "GET",
          path: "/api/contracts/do-not-build-v1.json"
        ),
        step("do-not-build-page", "The same register, explained.",
          method: "GET",
          path: "/docs/do-not-build-register"
        ),
        step("repositories-contract", "The repository creation and import contract.",
          method: "GET",
          path: "/api/contracts/repositories-v1.json"
        ),
        step("promises", "Filter a project board's items by promise state.",
          method: "GET",
          path: "/api/v3/repos/:owner/:repo/projectsV2/:project_number/items",
          query: "promise_state=LIVE",
          document: "docs/product-promises-registry.md"
        )
      ]
    }
  end

  # Advertising a capability that does not exist costs an agent a wasted
  # attempt and costs this document its credibility. Each entry names the route
  # a caller would reasonably try, and the contract test fails the moment one of
  # them starts resolving, so implementing the capability forces this list to be
  # corrected.
  defp not_available do
    [
      %{
        "id" => "bounty_settlement",
        "summary" => "Pricing, claiming, and settling a bounty over the API.",
        "state" =>
          "Implemented in the domain and not served. No route prices, claims, verifies, " <>
            "or settles a bounty, and no payment surface is reachable over HTTP.",
        "absent_route" => "POST /api/v3/repos/{owner}/{repo}/issues/{issue_number}/bounty",
        "policy_document" => "docs/bounty-settlement.md"
      },
      %{
        "id" => "accepted_outcome_contract",
        "summary" => "Reading the accepted-outcome contract over HTTP.",
        "state" =>
          "The contract artifact exists in the repository and no route serves it. An " <>
            "accepted outcome is reachable today only as promise evidence on a project item.",
        "absent_route" => "GET /api/contracts/accepted-outcome-v1.json",
        "policy_document" => "docs/accepted-outcome-contract.md"
      },
      %{
        "id" => "issue_receipt_link",
        "summary" => "Asking an issue for the receipts that carried its change to production.",
        "state" =>
          "Half published. An issue carries its attempts and the exact commit each ended " <>
            "at, and the push, build, and deploy receipts for a commit are read from the " <>
            "changelog or the commit page. The join from an issue to those receipt " <>
            "identifiers is still made by the reader.",
        "absent_route" => "GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}/receipts"
      },
      %{
        "id" => "openapi_document",
        "summary" => "An OpenAPI description of the API.",
        "state" =>
          "Not published. `GET /api/v3` carries the route inventory, the resource " <>
            "families, and the error envelope instead.",
        "absent_route" => "GET /api/v3/openapi.json"
      },
      %{
        "id" => "fork",
        "summary" => "Forking a repository to contribute without membership.",
        "state" =>
          "Not implemented. The contribution path from outside a repository's membership " <>
            "is a detailed issue.",
        "absent_route" => "POST /api/v3/repos/{owner}/{repo}/forks"
      },
      %{
        "id" => "automatic_github_mirroring",
        "summary" => "The forge mirroring `main` to GitHub on its own.",
        "state" =>
          "Configurable and not configured by default. Until an operator sets the mirror " <>
            "URLs for an environment, GitHub holds whatever was last pushed to it. Read " <>
            "the forge, not the mirror."
      }
    ]
  end

  defp exclusions do
    [
      "No credential, token, or secret appears in this document.",
      "No private repository, issue, account, or conversation appears in this document. " <>
        "Private data is reached only by an authenticated call to the routes named here, " <>
        "and each such route states the principal it requires.",
      "No internal host, queue, database, or deployment topology appears in this document.",
      "Reading this document grants nothing. It describes how to ask; every route still " <>
        "decides for itself."
    ]
  end

  # The agent participation scope rides an agent credential rather than a
  # personal API token, so it takes the token context's lifetime rule only
  # where that rule applies.
  defp scopes do
    token_scopes = ApiTokens.allowed_scopes()
    privileged = ApiTokens.privileged_scopes()

    (token_scopes ++ [@agent_scope])
    |> Enum.sort()
    |> Enum.map(fn scope ->
      %{"scope" => scope, "grants" => Map.fetch!(@scope_summaries, scope)}
      |> maybe_put("operator_only", scope in privileged)
      |> then(fn published ->
        if scope in token_scopes do
          Map.put(published, "maximum_lifetime_days", ApiTokens.maximum_lifetime_days([scope]))
        else
          published
        end
      end)
    end)
  end

  # A step that names a route carries the authority the application computes
  # for that exact route, so the document cannot claim an access rule the
  # router does not enforce.
  defp step(id, summary, options) do
    %{"id" => id, "summary" => summary}
    |> maybe_put("command", options[:command])
    |> maybe_put("note", options[:note])
    |> maybe_put("document", options[:document])
    |> maybe_put("query", options[:query])
    |> put_request(options[:method], options[:path])
  end

  defp put_request(step, nil, _path), do: step

  defp put_request(step, method, path) do
    step
    |> Map.put("method", method)
    |> Map.put("path", template(path))
    |> Map.put("access", access(method, path))
  end

  # Each surface has exactly one authority, and this publishes whichever one
  # owns the route. `/api/v3` belongs to `OpenAgentsWeb.ApiRouteAuthority`,
  # whose classifications are proven against what the enforcing pipeline does
  # to an anonymous request. Everything else belongs to the site-wide
  # `OpenAgentsWeb.RouteAuthority`. Publishing both for one route would let the
  # document contradict itself wherever the two are worded differently.
  defp access(method, path) do
    if String.starts_with?(path, "/api/v3") do
      api_access(method, path)
    else
      site_access(method, path)
    end
  end

  defp api_access(method, path) do
    verb = String.downcase(method)

    case ApiRouteAuthority.authority(verb, path) do
      nil ->
        nil

      authority ->
        %{
          "source" => "api",
          "authority" => Atom.to_string(authority),
          "summary" => Map.fetch!(@authority_summaries, authority),
          "family" => path |> then(&ApiRouteAuthority.family(verb, &1)) |> Atom.to_string(),
          "errors" => verb |> ApiRouteAuthority.error_contract(path) |> Atom.to_string(),
          "mutation" => verb not in ["get", "head"]
        }
    end
  end

  defp site_access(method, path) do
    case route(method, path) do
      nil ->
        nil

      found ->
        classified = RouteAuthority.classify(found)

        %{
          "source" => "site",
          "class" => to_string(classified.class),
          "summary" => classified.principal,
          "scope" => classified.scope,
          "mutation" => classified.mutation
        }
    end
  end

  @doc """
  The router route one published `METHOD path` pair names, or `nil`.

  Matching runs through `Phoenix.Router.route_info/4` rather than comparing
  strings, so a published concrete path such as `/docs/do-not-build-register`
  resolves to the dynamic route that actually serves it. Dynamic segments in a
  published path stand in for any value, so they are filled with a placeholder
  before matching.
  """
  @spec route(String.t(), String.t()) :: map() | nil
  def route(method, path) do
    concrete = Regex.replace(~r/:[a-z_]+/, path, "placeholder")

    case Phoenix.Router.route_info(
           OpenAgentsWeb.Router,
           String.upcase(method),
           concrete,
           "openagents.com"
         ) do
      :error ->
        nil

      %{plug: OpenAgentsWeb.NotFoundController} ->
        # Every reserved namespace carries a glob that answers not-found. A
        # path that lands there is served by nothing, which is exactly what a
        # capability listed as absent must keep doing.
        nil

      info ->
        %{
          verb: method |> String.downcase() |> String.to_existing_atom(),
          path: info.route,
          plug: info.plug,
          plug_opts: info.plug_opts
        }
    end
  end

  defp template(path),
    do: Regex.replace(~r/:([a-z_]+)/, path, fn _whole, segment -> "{#{segment}}" end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The Markdown is a rendering of the map above, never a second draft of it.
  defp render(document) do
    [
      "# ",
      document["title"],
      "\n\n",
      document["summary"],
      "\n\n",
      front_matter(document),
      Enum.map(document["sections"], &render_section/1),
      render_not_available(document["not_available"]),
      render_exclusions(document["exclusions"])
    ]
    |> IO.iodata_to_binary()
  end

  defp front_matter(document) do
    compatibility = document["compatibility"]

    [
      "- Contract: `",
      document["contract"],
      "`\n- Version: ",
      to_string(document["version"]),
      "\n- Revision: ",
      document["revision"],
      "\n- Digest: `",
      document["digest"],
      "`\n- Machine-readable: ",
      document["representations"]["machine"],
      "\n\n## Versioning\n\n",
      compatibility["detect_a_breaking_change"],
      "\n\n",
      compatibility["version_is_in_the_identifier"],
      "\n\n",
      compatibility["digest_scope"],
      "\n\n",
      compatibility["parity"],
      "\n\n"
    ]
  end

  defp render_section(section) do
    [
      "## ",
      section["title"],
      "\n\n",
      Enum.map(section["body"], &[&1, "\n\n"]),
      render_facts(section["facts"]),
      Enum.map(section["steps"] || [], &render_step/1),
      "\n"
    ]
  end

  defp render_facts(nil), do: []

  defp render_facts(facts) do
    rows =
      facts
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(&render_fact/1)

    [rows, "\n"]
  end

  defp render_fact({"scopes", scopes}) do
    [
      "- scopes:\n",
      Enum.map(scopes, fn scope ->
        operator = if scope["operator_only"], do: " Operator only.", else: ""

        lifetime =
          case scope["maximum_lifetime_days"] do
            nil -> ""
            days -> " At most #{days} days."
          end

        ["  - `", scope["scope"], "` — ", scope["grants"], operator, lifetime, "\n"]
      end)
    ]
  end

  defp render_fact({key, value}), do: ["- ", key, ": ", fact_value(value), "\n"]

  defp fact_value(value) when is_binary(value), do: value
  defp fact_value(value) when is_integer(value), do: to_string(value)

  defp fact_value(value) when is_list(value),
    do: value |> Enum.map(&fact_value/1) |> Enum.intersperse(", ")

  defp render_step(step) do
    [
      "- ",
      step["summary"],
      request_line(step),
      command_line(step),
      note_line(step),
      "\n"
    ]
  end

  defp request_line(%{"method" => method, "path" => path} = step) do
    query = if step["query"], do: "?" <> step["query"], else: ""

    access =
      case step["access"] do
        nil -> ""
        found -> " — " <> found["summary"]
      end

    ["\n  `", method, " ", path, query, "`", access]
  end

  defp request_line(_step), do: ""

  defp command_line(%{"command" => command}), do: ["\n\n      ", command, "\n"]
  defp command_line(_step), do: ""

  defp note_line(%{"note" => note}), do: ["\n  ", note]
  defp note_line(_step), do: ""

  defp render_not_available(entries) do
    [
      "## What is not there yet\n\n",
      "Each of these is something an agent might reasonably try. Read what each one says " <>
        "before you rely on it.\n\n",
      Enum.map(entries, fn entry ->
        [
          "- **",
          entry["summary"],
          "** ",
          entry["state"],
          absent_route_line(entry),
          document_line(entry),
          "\n"
        ]
      end),
      "\n"
    ]
  end

  defp absent_route_line(%{"absent_route" => route}), do: ["\n  No route: `", route, "`."]
  defp absent_route_line(_entry), do: ""

  defp document_line(%{"policy_document" => document}),
    do: ["\n  Policy: `", document, "` in the repository."]

  defp document_line(_entry), do: ""

  defp render_exclusions(exclusions) do
    [
      "## What this document never carries\n\n",
      Enum.map(exclusions, &["- ", &1, "\n"])
    ]
  end
end
