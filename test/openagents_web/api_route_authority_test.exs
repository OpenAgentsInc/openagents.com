defmodule OpenAgentsWeb.ApiRouteAuthorityTest do
  use OpenAgentsWeb.ConnCase

  import Phoenix.ConnTest

  @endpoint OpenAgentsWeb.Endpoint

  # Every live /api/v3 route must be classified exactly once. A route added to
  # the router without an entry in ApiRouteAuthority fails here, so a new
  # surface cannot inherit authority from a broad pipeline default.
  test "the inventory covers every api v3 route and nothing else" do
    live =
      OpenAgentsWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v3"))
      |> Enum.map(&{Atom.to_string(&1.verb), &1.path})
      |> MapSet.new()

    classified =
      OpenAgentsWeb.ApiRouteAuthority.routes()
      |> MapSet.new()

    unclassified = MapSet.difference(live, classified) |> MapSet.to_list()
    stale = MapSet.difference(classified, live) |> MapSet.to_list()

    assert MapSet.equal?(live, classified), """
    The route authority inventory disagrees with the router.

    Routes with no classification (add them to ApiRouteAuthority):

    #{unclassified |> Enum.map(fn {v, p} -> "  #{v} #{p}" end) |> Enum.join("\n")}

    Classified routes that no longer exist (remove them):

    #{stale |> Enum.map(fn {v, p} -> "  #{v} #{p}" end) |> Enum.join("\n")}
    """
  end

  # Each classification must match what the enforcing pipeline does to an
  # anonymous request. Requests name repositories that do not exist, so
  # authorized surfaces answer 404 and only authority failures can produce
  # 401.
  test "classifications match runtime enforcement" do
    for {verb, path} <- OpenAgentsWeb.ApiRouteAuthority.routes() do
      principal = OpenAgentsWeb.ApiRouteAuthority.authority(verb, path)
      status = dispatch_status(verb, path)

      case principal do
        :anonymous ->
          refute status == 401,
                 "#{verb} #{path} is classified :anonymous but an anonymous call got #{status}"

        :optional_bearer ->
          refute status == 401,
                 "#{verb} #{path} is classified :optional_bearer but an anonymous call got #{status}"

        :required_bearer ->
          assert status == 401,
                 "#{verb} #{path} is classified :required_bearer but an anonymous call got #{status}"
      end
    end
  end

  defp dispatch_status(verb, path) do
    path =
      path
      |> String.replace(":owner", "nobody")
      |> String.replace(":repo", "nonexistent")
      |> String.replace(":org", "nobody")
      |> String.replace(":issue_number", "1")
      |> String.replace(":milestone_number", "1")
      |> String.replace(":project_number", "1")
      |> String.replace(":item_id", "00000000-0000-4000-8000-000000000001")
      |> String.replace(":id", "00000000-0000-4000-8000-000000000001")
      |> String.replace(":name", "bug")
      |> String.replace(":assignee", "someone")

    build_conn()
    |> dispatch(@endpoint, String.to_atom(String.downcase(verb)), path)
    |> Map.get(:status)
  end
end
