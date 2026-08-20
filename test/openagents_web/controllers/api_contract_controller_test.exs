defmodule OpenAgentsWeb.ApiContractControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  test "repository contract bytes are public, versioned, and stable", %{conn: conn} do
    response = get(conn, ~p"/api/contracts/repositories-v1.json")

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(response, "cache-control") == ["public, max-age=300"]

    digest =
      response.resp_body
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert get_resp_header(response, "etag") == [~s("#{digest}")]
    contract = Jason.decode!(response.resp_body)
    assert contract["contract"] == "openagents.repositories.v1"
    assert contract["version"] == 1
  end
end
