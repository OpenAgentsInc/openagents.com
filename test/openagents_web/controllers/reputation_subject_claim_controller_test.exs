defmodule OpenAgentsWeb.ReputationSubjectClaimControllerTest do
  @moduledoc """
  The route half of #171: an account asks, and an operator decides.

  Before this, a reputation subject was whatever string an issuer typed and
  nothing on the surface let an account say a string was its own. These are the
  four routes that turn the binding into something a person can establish.
  """

  use OpenAgentsWeb.ConnCase

  alias OpenAgents.Reputation

  test "an account claims its own actor reference and reads the claim back", %{conn: conn} do
    user = github_user("api-token-reputation-claim")
    authed = put_forge_api_token(conn, "reputation-claim")

    created =
      authed
      |> post(~p"/api/v1/reputation/subject-claims", %{
        "subject_kind" => "account",
        "subject_id" => "user:" <> user.id
      })
      |> json_response(201)

    assert created["status"] == "pending"
    assert created["subject_kind"] == "account"
    assert created["subject_id"] == "user:" <> user.id

    listed =
      build_conn()
      |> put_forge_api_token("reputation-claim")
      |> get(~p"/api/v1/reputation/subject-claims")

    assert [claim] = json_response(listed, 200)["claims"]
    assert claim["id"] == created["id"]
  end

  test "a subject that is not this account's actor reference is refused", %{conn: conn} do
    body =
      conn
      |> put_forge_api_token("reputation-claim-wrong")
      |> post(~p"/api/v1/reputation/subject-claims", %{
        "subject_kind" => "account",
        "subject_id" => "user:" <> Ecto.UUID.generate()
      })
      |> json_response(422)

    assert body["message"] =~ "subject_id"
  end

  test "an unsupported kind is refused rather than stored", %{conn: conn} do
    body =
      conn
      |> put_forge_api_token("reputation-claim-kind")
      |> post(~p"/api/v1/reputation/subject-claims", %{
        "subject_kind" => "solver",
        "subject_id" => "actor:whoever"
      })
      |> json_response(422)

    assert body["message"] == "unsupported_subject_kind"
  end

  test "review is the operator's, and only a linked claim resolves", %{conn: conn} do
    user = github_user("api-token-reputation-claim-review")

    created =
      conn
      |> put_forge_api_token("reputation-claim-review")
      |> post(~p"/api/v1/reputation/subject-claims", %{
        "subject_kind" => "account",
        "subject_id" => "user:" <> user.id
      })
      |> json_response(201)

    assert Reputation.linked_subject_ids(user) == []

    assert build_conn()
           |> put_forge_api_token("reputation-claim-review")
           |> get(~p"/api/v1/reputation/subject-claims/pending")
           |> json_response(403)

    assert build_conn()
           |> put_forge_api_token("reputation-claim-review")
           |> patch(~p"/api/v1/reputation/subject-claims/#{created["id"]}", %{
             "status" => "linked"
           })
           |> json_response(403)

    assert Reputation.linked_subject_ids(user) == []

    grant_operator(github_user("api-token-reputation-claim-operator"))

    pending =
      build_conn()
      |> put_forge_api_token("reputation-claim-operator")
      |> get(~p"/api/v1/reputation/subject-claims/pending")
      |> json_response(200)

    assert Enum.any?(pending["claims"], &(&1["id"] == created["id"]))

    linked =
      build_conn()
      |> put_forge_api_token("reputation-claim-operator")
      |> patch(~p"/api/v1/reputation/subject-claims/#{created["id"]}", %{"status" => "linked"})
      |> json_response(200)

    assert linked["status"] == "linked"
    assert Reputation.linked_subject_ids(user) == ["user:" <> user.id]

    assert build_conn()
           |> put_forge_api_token("reputation-claim-operator")
           |> patch(~p"/api/v1/reputation/subject-claims/#{created["id"]}", %{
             "status" => "linked"
           })
           |> json_response(409)
  end

  test "a subject another account already claimed cannot be claimed again", %{conn: conn} do
    first = github_user("api-token-reputation-claim-first")

    conn
    |> put_forge_api_token("reputation-claim-first")
    |> post(~p"/api/v1/reputation/subject-claims", %{
      "subject_kind" => "account",
      "subject_id" => "user:" <> first.id
    })
    |> json_response(201)

    body =
      build_conn()
      |> put_forge_api_token("reputation-claim-second")
      |> post(~p"/api/v1/reputation/subject-claims", %{
        "subject_kind" => "account",
        "subject_id" => "user:" <> first.id
      })
      |> json_response(422)

    assert body["message"] =~ "subject_id"
  end
end
