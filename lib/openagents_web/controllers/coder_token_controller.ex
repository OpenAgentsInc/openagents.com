defmodule OpenAgentsWeb.CoderTokenController do
  @moduledoc "Mints a short-lived Coder-audience token for the authenticated account."

  use OpenAgentsWeb, :controller

  @coder_token_salt "coder-token"
  @coder_token_ttl_seconds 3600

  def create(conn, _params) do
    user = conn.assigns.current_user
    now = System.system_time(:second)

    token =
      Phoenix.Token.sign(
        OpenAgentsWeb.Endpoint,
        @coder_token_salt,
        %{
          "sub" => user.id,
          "aud" => "coder",
          "iat" => now,
          "exp" => now + @coder_token_ttl_seconds,
          "jti" => Ecto.UUID.generate(),
          "scope" => "responses"
        }
      )

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      "token" => token,
      "audience" => "coder",
      "expires_in" => @coder_token_ttl_seconds
    })
  end
end
