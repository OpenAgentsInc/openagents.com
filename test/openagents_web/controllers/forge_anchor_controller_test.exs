defmodule OpenAgentsWeb.ForgeAnchorControllerTest do
  @moduledoc """
  EXIT-005, ADR 0008. The anchor is only worth publishing if a stranger can
  fetch it with no credential and hash exactly what they fetched.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Forge.Anchor

  test "an anonymous reader fetches the stored bytes verbatim", %{conn: conn} do
    {:ok, published} = Anchor.publish()

    conn = get(conn, Anchor.path())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

    # Byte-for-byte, because the digest a reader computes is a digest of what
    # they fetched and the next anchor names that digest as its
    # `previous_digest`. Re-encoding here would break every archived copy.
    assert conn.resp_body == published.body
    assert Anchor.digest(conn.resp_body) == published.digest
  end

  test "the head a reader takes from the response is the head the log carries", %{conn: conn} do
    {:ok, _published} = Anchor.publish()

    body = conn |> get(Anchor.path()) |> response(200) |> Jason.decode!()

    assert body["schema"] == Anchor.schema()
    assert is_integer(body["anchor_seq"])
    assert is_list(body["repositories"])
    refute body["witnessed"]
    refute body["signed"]
  end

  test "an unpublished anchor says so rather than going silent", %{conn: conn} do
    body = conn |> get(Anchor.path()) |> json_response(404)

    assert body["published"] == false
    assert body["reason"] =~ "no anchor"
  end

  test "the latest anchor is the one served", %{conn: conn} do
    {:ok, _first} = Anchor.publish()
    {:ok, second} = Anchor.publish()

    body = conn |> get(Anchor.path()) |> response(200) |> Jason.decode!()

    assert body["anchor_seq"] == second.anchor_seq
    assert body["previous_digest"] == second.previous_digest
  end
end
