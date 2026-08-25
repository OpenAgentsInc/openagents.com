defmodule OpenAgentsWeb.Plugs.AmbientApiTokenAuth do
  @moduledoc """
  Recognizes an account when one presents a valid credential, and refuses
  nobody.

  `OpenAgentsWeb.Plugs.OptionalApiTokenAuth` widens what an anonymous caller
  may *read*, so a credential it cannot verify is an error worth a `401`. This
  plug does something different: it grants no authority at all. It only lets a
  route that already answers anonymously know whose account is on the other
  end, so the route can add what that account is owed — its memories, on
  `POST /api/v1/responses` — and answer exactly as before when it cannot tell.

  Because nothing here is granted, nothing here is refused. A malformed header,
  an expired token, a token scoped for something else: each leaves
  `:current_user` `nil` and the request proceeds as the anonymous request it
  already was. Refusing instead would break every caller that reaches an
  anonymous route with an unrelated `Authorization` header — which is a live
  shape on this endpoint, and which was working before recall existed.

  A route behind this plug must therefore treat `:current_user` as a
  convenience and never as authorization. If a route needs authority, it
  belongs on `ApiTokenAuth` instead.
  """

  import Plug.Conn

  alias OpenAgents.ApiTokens

  def init(options), do: Keyword.fetch!(options, :scope)

  def call(conn, required_scope) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> recognize(conn, token, required_scope)
      _absent_or_unreadable -> anonymous(conn)
    end
  end

  defp recognize(conn, token, required_scope) do
    case ApiTokens.authenticate(token, required_scope) do
      {:ok, user, api_token} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> assign(:current_user, user)
        |> assign(:api_token, api_token)
        |> assign(:api_scope, required_scope)

      {:error, :invalid_api_token} ->
        anonymous(conn)
    end
  end

  defp anonymous(conn) do
    conn
    |> assign(:current_user, nil)
    |> assign(:api_token, nil)
    |> assign(:api_scope, nil)
  end
end
