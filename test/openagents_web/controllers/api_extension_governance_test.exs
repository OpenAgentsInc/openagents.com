defmodule OpenAgentsWeb.ApiExtensionGovernanceTest do
  @moduledoc """
  The rule that makes the extension surface governed rather than documented.

  A field only counts as part of the API once `GET /api/v1` enumerates it, and
  a filter only counts once the endpoint it names actually rejects a value
  outside its enum. These tests read the root document and the live responses
  and refuse any disagreement between them, so adding a field to the
  `openagents` object without publishing it fails here rather than in a
  client.
  """
  use OpenAgentsWeb.ConnCase

  alias OpenAgents.Inference.{Credit, Grant}
  alias OpenAgents.Issues
  alias OpenAgents.ProjectItems
  alias OpenAgents.Projects
  alias OpenAgents.Repositories

  setup %{conn: conn} do
    repository = Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
    {:ok, conn: put_forge_api_token(conn, "governance", repository), repository: repository}
  end

  test "every field an issue response carries is enumerated in the root document", %{
    conn: conn,
    repository: repository
  } do
    {:ok, blocked} = Issues.create_issue(repository, %{title: "Waiting"})
    {:ok, blocker} = Issues.create_issue(repository, %{title: "Prerequisite"})
    :ok = Issues.add_dependencies(blocked, [blocker.number])
    place(repository, blocked, "In Progress")

    documented = documented_fields(conn, "issue.openagents")

    show = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/issues/#{blocked.number}")
    served = show |> json_response(200) |> Map.fetch!("openagents") |> Map.keys() |> Enum.sort()

    assert served == documented

    index = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/issues")

    for issue <- json_response(index, 200)["issues"] do
      assert issue |> Map.fetch!("openagents") |> Map.keys() |> Enum.sort() == documented
    end
  end

  test "the extension a response names in its header is one the root document lists", %{
    conn: conn,
    repository: repository
  } do
    {:ok, issue} = Issues.create_issue(repository, %{title: "Named"})

    show = get(conn, ~p"/api/v1/repos/OpenAgentsInc/openagents.com/issues/#{issue.number}")
    [named] = get_resp_header(show, "x-openagents-extensions")

    extensions = conn |> get(~p"/api/v1") |> json_response(200) |> Map.fetch!("extensions")

    for name <- String.split(named, ",", trim: true) do
      assert Map.has_key?(extensions, String.trim(name))
    end
  end

  test "every documented filter is enforced by the endpoint that documents it", %{conn: conn} do
    filters =
      conn
      |> get(~p"/api/v1")
      |> json_response(200)
      |> get_in(["extensions", "issue.openagents", "filters"])

    assert map_size(filters) > 0

    for {name, filter} <- filters do
      path = filter_path(filter)

      refused = get(conn, "#{path}?#{name}=not-a-legal-value")

      assert %{"errors" => errors} = json_response(refused, 422),
             "#{name} is documented as a filter on #{path} but accepts any value"

      assert Map.has_key?(errors, name),
             "#{name} refused an illegal value without naming the field"

      for value <- documented_values(filter) do
        accepted = get(conn, "#{path}?#{name}=#{value}")
        assert json_response(accepted, 200)
      end
    end
  end

  test "the progress enum the root document publishes is the one the context derives", %{
    conn: conn
  } do
    field =
      conn
      |> get(~p"/api/v1")
      |> json_response(200)
      |> get_in(["extensions", "issue.openagents", "fields", "progress"])

    assert field["enum"] == Issues.progress_values()
  end

  test "the backend enum the root document publishes is the one the context derives", %{
    conn: conn
  } do
    parameter =
      conn
      |> get(~p"/api/v1")
      |> json_response(200)
      |> get_in(["extensions", "chat.openagents", "parameters", "model"])

    assert parameter["enum"] == OpenAgents.Chat.Backends.ids()
    assert parameter["default"] == OpenAgents.Chat.Backends.default_id()
    assert parameter["default"] in parameter["enum"]
  end

  test "every published backend is one a turn actually accepts", %{conn: conn} do
    document = conn |> get(~p"/api/v1") |> json_response(200)
    published = get_in(document, ["extensions", "chat.openagents", "backends"])

    assert Enum.map(published, & &1["id"]) == OpenAgents.Chat.Backends.ids()

    # A published id the endpoint would refuse is the drift this rule exists to
    # catch, so each one is offered to the endpoint that names it.
    for backend <- published do
      accepted =
        conn
        |> put_chat_api_token("governance-backend-" <> backend["id"])
        |> post(~p"/api/v1/chat/turns", %{"message" => "Hello.", "model" => backend["id"]})

      assert json_response(accepted, 202)["turn"]["model"] == backend["id"]
    end
  end

  test "a model outside the published enum is refused with a field-level 422", %{conn: conn} do
    refusal =
      conn
      |> put_chat_api_token("governance-backend-unknown")
      |> post(~p"/api/v1/chat/turns", %{"message" => "Hello.", "model" => "not-a-legal-value"})

    assert %{"errors" => errors} = json_response(refusal, 422)
    assert Map.has_key?(errors, "model")
  end

  test "the thread enums the root document publishes are the ones the context derives", %{
    conn: conn
  } do
    parameters =
      conn
      |> get(~p"/api/v1")
      |> json_response(200)
      |> get_in(["extensions", "thread.openagents", "parameters"])

    assert parameters["reasoning"]["enum"] == OpenAgents.Threads.Thread.reasoning_efforts()
    assert parameters["reasoning"]["default"] == OpenAgents.Threads.default_reasoning()
    assert parameters["reasoning"]["default"] in parameters["reasoning"]["enum"]

    assert parameters["permission_profile"]["enum"] ==
             OpenAgents.Threads.Thread.permission_profiles()

    assert parameters["permission_profile"]["default"] ==
             OpenAgents.Threads.default_permission_profile()

    assert parameters["permission_profile"]["default"] in parameters["permission_profile"]["enum"]
  end

  test "the thread budget the root document publishes is the one a thread is minted with", %{
    conn: conn
  } do
    limits =
      conn
      |> get(~p"/api/v1")
      |> json_response(200)
      |> get_in(["extensions", "thread.openagents", "limits"])

    ceilings = OpenAgents.Threads.ceilings()

    assert limits["maximum_open_threads_per_account"] ==
             OpenAgents.Threads.maximum_open_per_account()

    assert limits["grant"]["max_total_tokens"] == ceilings.max_total_tokens
    assert limits["grant"]["max_calls"] == ceilings.max_calls
    assert limits["grant"]["ttl_seconds"] == ceilings.ttl_seconds

    # The cost figure is the account's credit rather than a per-thread cap, so
    # the document publishes the allowances and the mint reports the remainder.
    refute Map.has_key?(limits["grant"], "max_cost_microusd")
    # The published figure is what a new account is granted. It is no longer
    # what every account holds — the allowance is recorded per account — and
    # the document says so, pointing a caller at `GET /api/v1/credit` for its
    # own.
    assert limits["credit"]["account_microusd"] == Credit.new_account_allowance()
    assert limits["credit"]["description"] =~ "GET /api/v1/credit"
    assert limits["credit"]["visitor_microusd"] == Credit.visitor_allowance()

    created =
      conn
      |> put_chat_api_token("governance-thread-budget")
      |> post(~p"/api/v1/threads", %{"objective" => "Measure the published budget."})
      |> json_response(201)

    granted = created["grant"]["limits"]
    owner = OpenAgents.Repo.get_by!(Grant, thread_id: created["thread"]["id"]).owner_visitor_id

    assert granted["max_total_tokens"] == limits["grant"]["max_total_tokens"]
    assert granted["max_calls"] == limits["grant"]["max_calls"]
    assert granted["max_cost_microusd"] == Credit.remaining(owner)
  end

  test "every published thread parameter value is one the route actually accepts", %{conn: conn} do
    parameters =
      conn
      |> get(~p"/api/v1")
      |> json_response(200)
      |> get_in(["extensions", "thread.openagents", "parameters"])

    for {name, parameter} <- Map.take(parameters, ["reasoning", "permission_profile"]),
        value <- parameter["enum"] do
      accepted =
        conn
        |> put_chat_api_token("governance-thread-#{name}-#{value}")
        |> post(~p"/api/v1/threads", %{"objective" => "Accept #{value}.", name => value})

      assert json_response(accepted, 201)["thread"]

      refused =
        conn
        |> put_chat_api_token("governance-thread-#{name}-refused")
        |> post(~p"/api/v1/threads", %{
          "objective" => "Refuse anything else.",
          name => "not-a-legal-value"
        })

      assert %{"errors" => errors} = json_response(refused, 422),
             "#{name} is published with an enum but accepts any value"

      assert Map.has_key?(errors, name)
    end
  end

  defp documented_fields(conn, extension) do
    conn
    |> get(~p"/api/v1")
    |> json_response(200)
    |> get_in(["extensions", extension, "fields"])
    |> Map.keys()
    |> Enum.sort()
  end

  defp filter_path(%{"endpoint" => endpoint}) do
    endpoint
    |> String.split(" ", parts: 2)
    |> List.last()
    |> String.replace("{owner}", "OpenAgentsInc")
    |> String.replace("{repo}", "openagents.com")
  end

  defp documented_values(%{"enum" => values}), do: values
  defp documented_values(%{"type" => "boolean"}), do: ["true", "false"]

  defp place(repository, issue, column) do
    {:ok, project} = Projects.create_project(repository, %{title: "Board", owner: "OpenAgents"})

    {:ok, item} =
      ProjectItems.create_project_item(repository, %{
        project_id: project.id,
        issue_id: issue.id,
        issue_repository_id: issue.repository_id,
        values: %{"Status" => column}
      })

    item
  end
end
