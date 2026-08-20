defmodule OpenAgents.Test.RepositoryCliGitHubFake do
  @moduledoc false

  import Plug.Conn

  def init(options), do: Map.new(options)

  def call(conn, options) do
    case {conn.method, conn.request_path} do
      {"GET", "/user/memberships/orgs"} ->
        json(conn, [])

      {"GET", "/repos/" <> full_name} when full_name == options.source_full_name ->
        json(conn, %{
          "id" => options.repository_id,
          "node_id" => "R_#{options.repository_id}",
          "name" => full_name |> String.split("/") |> List.last(),
          "full_name" => full_name,
          "private" => true,
          "description" => "Disposable CLI import fixture",
          "default_branch" => options.default_branch,
          "owner" => %{
            "id" => options.owner_id,
            "node_id" => "U_#{options.owner_id}",
            "login" => full_name |> String.split("/") |> List.first(),
            "avatar_url" => "https://avatars.githubusercontent.com/u/#{options.owner_id}?v=4",
            "type" => "User"
          },
          "permissions" => %{"pull" => true, "push" => true, "admin" => true}
        })

      {"GET", "/repos/" <> rest} ->
        reference_response(conn, rest, options)

      _unmatched ->
        send_resp(conn, 404, "not found")
    end
  end

  defp reference_response(conn, rest, options) do
    prefix = options.source_full_name <> "/git/matching-refs/"

    cond do
      rest == options.source_full_name <> "/git/trees/" <> options.default_branch ->
        json(conn, %{"truncated" => false, "tree" => []})

      String.starts_with?(rest, prefix) ->
        kind = rest |> String.replace_prefix(prefix, "") |> String.trim_trailing("/")
        expected_prefix = "refs/#{kind}/"

        refs =
          options.refs
          |> Enum.filter(fn {name, _value} -> String.starts_with?(name, expected_prefix) end)
          |> Enum.map(fn {name, value} ->
            %{"ref" => name, "object" => %{"type" => value.type, "sha" => value.sha}}
          end)

        json(conn, refs)

      true ->
        send_resp(conn, 404, "not found")
    end
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
