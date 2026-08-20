defmodule OpenAgentsWeb.ApiContractController do
  @moduledoc "Serves immutable, versioned public API contract artifacts."

  use OpenAgentsWeb, :controller

  @repository_contract Application.app_dir(
                         :openagents,
                         "priv/api-contracts/repositories-v1.json"
                       )

  def repositories_v1(conn, _params) do
    contract = File.read!(@repository_contract)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("etag", ~s("#{sha256(contract)}"))
    |> send_resp(:ok, contract)
  end

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
