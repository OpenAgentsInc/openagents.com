defmodule OpenAgentsWeb.ApiContractController do
  @moduledoc "Serves immutable, versioned public API contract artifacts."

  use OpenAgentsWeb, :controller

  @contract_path "priv/api-contracts/repositories-v1.json"

  def repositories_v1(conn, _params) do
    contract = File.read!(contract_file())

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("etag", ~s("#{sha256(contract)}"))
    |> send_resp(:ok, contract)
  end

  # Resolved when the request is served, not when the module is compiled. As a
  # module attribute this baked the *build* machine's `_build` path into the
  # release, and that path does not exist in the image that runs it -- so
  # `File.read!/1` raised and this endpoint answered 500 in every deployed
  # environment while passing everywhere it was compiled and run together.
  defp contract_file, do: Application.app_dir(:openagents, @contract_path)

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
