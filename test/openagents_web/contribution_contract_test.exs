defmodule OpenAgentsWeb.ContributionContractTest do
  @moduledoc """
  The rule that makes the agent front door governed rather than merely written.

  An agent acts on this document, so a claim in it that the application does
  not keep is worse than no document at all. Every published claim is checked
  against the thing it claims: paths against the router, authority against the
  route authority, scopes against the token context, files against the working
  tree, push targets against the push guard, and absences against the router
  again, so implementing one of the listed absences fails here until the list
  is corrected.
  """
  use OpenAgentsWeb.ConnCase

  alias OpenAgents.ApiTokens
  alias OpenAgents.Issues
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiRouteAuthority
  alias OpenAgentsWeb.ContributionContract
  alias OpenAgentsWeb.RouteAuthority

  @agent_scope "agent:participate"

  setup %{conn: conn} do
    {:ok, conn: conn, repository: Repositories.get_by_path!("OpenAgentsInc", "openagents.com")}
  end

  describe "publication" do
    test "both representations are served anonymously", %{conn: conn} do
      machine = get(conn, ~p"/agents.json")
      assert machine.status == 200
      assert content_type(machine) =~ "application/json"

      human = get(build_conn(), ~p"/agents.md")
      assert human.status == 200
      assert content_type(human) =~ "text/markdown"
    end

    test "the human and machine forms carry the same identity", %{conn: conn} do
      document = document(conn)
      markdown = markdown(conn)

      assert markdown =~ "`#{document["contract"]}`"
      assert markdown =~ "Version: #{document["version"]}"
      assert markdown =~ "Revision: #{document["revision"]}"
      assert markdown =~ "`#{document["digest"]}`"
    end

    test "everything the machine form says appears in the human form", %{conn: conn} do
      document = document(conn)
      markdown = markdown(conn)

      for section <- document["sections"] do
        assert markdown =~ section["title"]

        for paragraph <- section["body"], do: assert(markdown =~ paragraph)
        for step <- section["steps"], do: assert(markdown =~ step["summary"])
      end

      for entry <- document["not_available"] do
        assert markdown =~ entry["summary"]
        assert markdown =~ entry["state"]
      end

      for exclusion <- document["exclusions"], do: assert(markdown =~ exclusion)

      for scope <- scopes(document), do: assert(markdown =~ scope["scope"])
    end

    test "the digest is the document with the digest removed", %{conn: conn} do
      document = document(conn)
      {published, rest} = Map.pop!(document, "digest")

      assert published == ContributionContract.digest("http://www.example.com")
      assert published =~ ~r/^sha256:[0-9a-f]{64}$/
      refute published == ContributionContract.digest("https://elsewhere.example")
      refute rest == document
    end

    test "the API description points at the contract with a matching digest", %{conn: conn} do
      contribution = conn |> get(~p"/api/v1") |> json_response(200) |> Map.fetch!("contribution")
      document = document(conn)

      assert contribution["contract"] == document["contract"]
      assert contribution["version"] == document["version"]
      assert contribution["revision"] == document["revision"]
      assert contribution["digest"] == document["digest"]
      assert contribution["machine"] == document["representations"]["machine"]
      assert contribution["human"] == document["representations"]["human"]
    end

    test "the contract identifier carries its major version", %{conn: conn} do
      document = document(conn)

      assert document["contract"] == "openagents.contribution.v#{document["version"]}"
    end
  end

  describe "governance" do
    test "every published request resolves in the router", %{conn: conn} do
      requests = requests(document(conn))

      assert length(requests) > 10

      for request <- requests do
        assert ContributionContract.route(request["method"], router_path(request)),
               "the front door publishes #{request["method"]} #{request["path"]}, " <>
                 "which no route serves"
      end
    end

    test "every published request outside the API states what the site authority says", %{
      conn: conn
    } do
      site = Enum.filter(requests(document(conn)), &(&1["access"]["source"] == "site"))

      assert site != []

      for request <- site do
        found = ContributionContract.route(request["method"], router_path(request))
        classified = RouteAuthority.classify(found)

        assert request["access"]["class"] == to_string(classified.class)
        assert request["access"]["summary"] == classified.principal
        assert request["access"]["scope"] == classified.scope
        assert request["access"]["mutation"] == classified.mutation
        refute classified.class == :unclassified
      end
    end

    test "every published API request states what the API authority says", %{conn: conn} do
      api = Enum.filter(requests(document(conn)), &String.starts_with?(&1["path"], "/api/v1"))

      assert api != []

      for request <- api do
        path = router_path(request)
        verb = String.downcase(request["method"])

        assert request["access"]["source"] == "api"

        assert ApiRouteAuthority.authority(verb, path),
               "#{request["method"]} #{path} is not in the API route inventory"

        assert request["access"]["authority"] ==
                 to_string(ApiRouteAuthority.authority(verb, path))

        assert request["access"]["family"] == to_string(ApiRouteAuthority.family(verb, path))

        assert request["access"]["errors"] ==
                 to_string(ApiRouteAuthority.error_contract(verb, path))
      end
    end

    # One authority per surface, so the document cannot hold two answers for
    # the same route. `POST /api/v1/agents/register` is the case that proves it
    # matters: the API inventory calls it anonymous, because that is what the
    # pipeline does, and the site-wide inventory's catch-all for `/api/v1`
    # writes would have called it a bearer route.
    test "no API request is described by the site-wide authority", %{conn: conn} do
      for request <- requests(document(conn)) do
        if String.starts_with?(request["path"], "/api/v1") do
          assert request["access"]["source"] == "api"
          refute Map.has_key?(request["access"], "class")
        else
          assert request["access"]["source"] == "site"
          refute Map.has_key?(request["access"], "authority")
        end
      end
    end

    test "every published request carries a phrase saying what it needs", %{conn: conn} do
      for request <- requests(document(conn)) do
        assert is_binary(request["access"]["summary"])
        assert request["access"]["summary"] != ""
      end
    end

    test "the published scopes are the scopes the token context allows", %{conn: conn} do
      published = document(conn) |> scopes() |> Enum.map(& &1["scope"])

      assert published == Enum.sort(ApiTokens.allowed_scopes() ++ [@agent_scope])

      for scope <- published, do: assert(is_binary(scope))
    end

    test "each published ordinary scope creates a real token", %{conn: conn} do
      user = repository_user_fixture("front-door-scopes")

      ordinary =
        document(conn)
        |> scopes()
        |> Enum.reject(&(&1["scope"] == @agent_scope or &1["operator_only"]))

      assert ordinary != []

      for %{"scope" => scope} <- ordinary do
        assert {:ok, token, plaintext} =
                 ApiTokens.create(user, %{
                   "name" => scope,
                   "scopes" => [scope],
                   "lifetime_days" => 1
                 })

        assert token.scopes == [scope]
        assert String.starts_with?(plaintext, "oa_pat_")
      end
    end

    test "a scope the document marks operator-only is refused to everyone else", %{conn: conn} do
      user = repository_user_fixture("front-door-privileged")

      operator_only =
        document(conn)
        |> scopes()
        |> Enum.filter(& &1["operator_only"])
        |> Enum.map(& &1["scope"])

      assert operator_only == Enum.sort(ApiTokens.privileged_scopes())

      for scope <- operator_only do
        assert {:error, :invalid_api_token} =
                 ApiTokens.create(user, %{"name" => scope, "scopes" => [scope]})
      end
    end

    test "each published token scope states the lifetime the token context allows it", %{
      conn: conn
    } do
      published = scopes(document(conn))

      for scope <- published, scope["scope"] in ApiTokens.allowed_scopes() do
        assert scope["maximum_lifetime_days"] ==
                 ApiTokens.maximum_lifetime_days([scope["scope"]])
      end

      # The agent scope rides an agent credential, so it must not borrow the
      # personal token's lifetime rule.
      agent = Enum.find(published, &(&1["scope"] == @agent_scope))

      refute Map.has_key?(agent, "maximum_lifetime_days")
    end

    test "the published token facts match the token context", %{conn: conn} do
      facts = facts(document(conn), "authentication")

      assert facts["maximum_lifetime_days"] == ApiTokens.maximum_lifetime_days([])
      assert facts["human_token_prefix"] == "oa_pat_"
    end

    test "every repository file the document names exists", %{conn: conn} do
      document = document(conn)

      named =
        Enum.map(document["not_available"], & &1["policy_document"]) ++
          Enum.map(requests(document), & &1["document"]) ++
          [facts(document, "forge")["guard"]]

      named = named |> Enum.reject(&is_nil/1) |> Enum.uniq()

      assert named != []

      for path <- named do
        assert File.exists?(path), "the front door names #{path}, which is not in the repository"
      end
    end

    test "a capability the document lists as absent stays absent", %{conn: conn} do
      absent =
        document(conn)
        |> Map.fetch!("not_available")
        |> Enum.map(& &1["absent_route"])
        |> Enum.reject(&is_nil/1)

      assert length(absent) >= 5

      for entry <- absent do
        [method, path] = String.split(entry, " ", parts: 2)

        refute ContributionContract.route(method, untemplate(path)),
               "the front door says #{entry} does not exist, but a route now serves it"
      end
    end
  end

  describe "the forge is the only push target" do
    # The guard admits the forge's hosts, so this asks the question of the
    # document as a production deployment serves it rather than as the test
    # endpoint's `example.com` origin does.
    test "the push guard admits the remote the document publishes" do
      facts =
        "https://openagents.com"
        |> ContributionContract.document()
        |> Jason.encode!()
        |> Jason.decode!()
        |> facts("forge")

      url =
        facts["push_remote_url_template"]
        |> String.replace("{owner}", "OpenAgentsInc")
        |> String.replace("{repo}", "openagents.com")

      assert {_output, 0} = guard("openagents", url)
    end

    test "the push guard refuses every target the document names as refused", %{conn: conn} do
      facts = facts(document(conn), "forge")

      assert facts["refused_push_targets"] != []

      for template <- facts["refused_push_targets"] do
        url =
          template
          |> String.replace("{owner}", "OpenAgentsInc")
          |> String.replace("{repo}", "openagents.com")

        assert {output, 1} = guard("origin", url)
        assert output =~ "Refusing to push"
      end
    end

    test "no published command pushes anywhere but the forge remote", %{conn: conn} do
      commands =
        document(conn)
        |> requests(fn step -> step["command"] end)
        |> Enum.filter(&String.contains?(&1, "git push"))

      assert commands != []

      for command <- commands do
        assert command =~ "git push openagents"
        refute command =~ "github.com"
      end
    end

    # GitHub may be named, but only as a target the guard refuses. Counting the
    # mentions catches a later edit that adds a GitHub URL somewhere the reader
    # could mistake for an instruction.
    test "GitHub appears only in the list of refused push targets", %{conn: conn} do
      document = document(conn)
      refused = facts(document, "forge")["refused_push_targets"]
      expected = Enum.count(refused, &String.contains?(&1, "github.com"))

      assert expected == 2

      for body <- [Jason.encode!(document), markdown(conn)] do
        assert length(String.split(body, "github.com")) - 1 == expected
        assert body =~ "Never push to GitHub"
      end
    end
  end

  describe "the document carries no private data" do
    test "a private repository and its issues are absent", %{conn: conn} do
      private = repository_fixture(%{visibility: "private"})
      {:ok, issue} = Issues.create_issue(private, %{title: "Unreleased embargoed programme"})

      for body <- [Jason.encode!(document(conn)), markdown(conn)] do
        refute body =~ private.name
        refute body =~ issue.title
      end
    end

    test "the document is identical for an anonymous and an authenticated reader", %{
      conn: conn,
      repository: repository
    } do
      anonymous = get(build_conn(), ~p"/agents.json")
      authenticated = get(put_forge_api_token(conn, "front-door", repository), ~p"/agents.json")

      assert anonymous.resp_body == authenticated.resp_body
    end

    test "the document says what it withholds and why", %{conn: conn} do
      exclusions = Map.fetch!(document(conn), "exclusions")

      assert length(exclusions) >= 4
      assert Enum.any?(exclusions, &(&1 =~ "credential"))
      assert Enum.any?(exclusions, &(&1 =~ "private"))
    end
  end

  describe "cold start" do
    test "the document alone reaches one issue and its acceptance criteria", %{
      conn: conn,
      repository: repository
    } do
      {:ok, ready} =
        Issues.create_issue(repository, %{
          title: "Ready to start",
          body: "## Acceptance criteria\n\nThe front door resolves without crawling."
        })

      {:ok, waiting} = Issues.create_issue(repository, %{title: "Waiting"})
      {:ok, blocker} = Issues.create_issue(repository, %{title: "Prerequisite"})
      :ok = Issues.add_dependencies(waiting, [blocker.number])

      document = document(conn)

      # Step one: the queue the document names, called by an anonymous client.
      queue = step(document, "discovery", "ready-queue")
      queue_path = fill(queue["path"]) <> "?" <> queue["query"]

      numbers =
        build_conn()
        |> get(queue_path)
        |> json_response(200)
        |> Map.fetch!("issues")
        |> Enum.map(& &1["number"])

      assert ready.number in numbers
      refute waiting.number in numbers

      # Step two: the issue the document names, with its criteria in the body.
      issue = step(document, "discovery", "issue")
      path = issue["path"] |> fill() |> String.replace("{issue_number}", "#{ready.number}")

      body = build_conn() |> get(path) |> json_response(200)

      assert body["body"] =~ "Acceptance criteria"
      assert body["openagents"]["blocked"] == false
    end

    test "the label the document names as a convention is a legal filter", %{conn: conn} do
      queue = step(document(conn), "discovery", "labels")

      assert queue["note"] =~ "agent-ready"

      response =
        get(build_conn(), "/api/v1/repos/OpenAgentsInc/openagents.com/issues?labels=agent-ready")

      assert json_response(response, 200)["issues"] == []
    end
  end

  defp document(conn), do: conn |> get(~p"/agents.json") |> json_response(200)
  defp markdown(_conn), do: build_conn() |> get(~p"/agents.md") |> response(200)

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> List.first()

  defp section(document, id),
    do: Enum.find(Map.fetch!(document, "sections"), &(&1["id"] == id))

  defp facts(document, id), do: document |> section(id) |> Map.fetch!("facts")

  defp scopes(document), do: facts(document, "authentication")["scopes"]

  defp step(document, section_id, step_id),
    do:
      document |> section(section_id) |> Map.fetch!("steps") |> Enum.find(&(&1["id"] == step_id))

  defp requests(document), do: requests(document, &(&1["method"] && &1))

  defp requests(document, selector) do
    document
    |> Map.fetch!("sections")
    |> Enum.flat_map(&Map.fetch!(&1, "steps"))
    |> Enum.map(selector)
    |> Enum.reject(&is_nil/1)
  end

  # The document publishes `{owner}`; the router and the API inventory speak
  # `:owner`.
  defp router_path(request), do: untemplate(request["path"])

  defp untemplate(path),
    do: Regex.replace(~r/\{([a-z_]+)\}/, path, fn _whole, segment -> ":#{segment}" end)

  defp fill(path),
    do:
      path
      |> String.replace("{owner}", "OpenAgentsInc")
      |> String.replace("{repo}", "openagents.com")

  defp guard(remote, url),
    do: System.cmd("sh", ["ops/ci/push-remote-check.sh", remote, url], stderr_to_stdout: true)
end
