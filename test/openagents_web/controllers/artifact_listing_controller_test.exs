defmodule OpenAgentsWeb.ArtifactListingControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  import OpenAgents.ArtifactCatalogFixtures
  import Phoenix.LiveViewTest

  alias OpenAgents.ArtifactCatalog

  test "catalog API requires an authenticated OpenAgents session", %{conn: conn} do
    conn = get(conn, ~p"/api/artifact-listings")

    assert json_response(conn, 401) == %{"error" => "authentication_required"}
  end

  test "catalog API lists, searches, shows, and exports redacted metadata", %{conn: conn} do
    listing = publish_listing!(%{owner_description: "Low-risk navigation traces"})
    _other = publish_listing!(%{owner_description: "SQL evaluation dataset"})
    conn = log_in_github_user(conn, "artifact-catalog-api")

    searched = get(conn, ~p"/api/artifact-listings?q=navigation")
    assert %{"listings" => [projection]} = json_response(searched, 200)
    assert projection["id"] == listing.id
    refute inspect(projection) =~ listing.source_ref

    shown = searched |> recycle() |> get(~p"/api/artifact-listings/#{listing.id}")
    assert json_response(shown, 200)["listing"]["listing_digest"] == listing.listing_digest

    exported =
      shown
      |> recycle()
      |> get(~p"/api/artifact-listings/#{listing.id}/export")

    assert json_response(exported, 200)["listing"]["artifact_digest"] == listing.artifact_digest
    assert [disposition] = get_resp_header(exported, "content-disposition")
    assert disposition =~ "attachment"
    refute inspect(json_response(exported, 200)) =~ listing.source_ref
  end

  test "catalog LiveView searches safe listings without rendering source references", %{
    conn: conn
  } do
    matching = publish_listing!(%{owner_description: "Browser navigation trace"})
    other = publish_listing!(%{owner_description: "Database query dataset"})
    conn = log_in_github_user(conn, "artifact-catalog-live")

    {:ok, view, html} = live(conn, ~p"/artifact-catalog")
    assert html =~ "Licensed artifacts"
    assert has_element?(view, "#artifact-listing-#{matching.id}")
    assert has_element?(view, "#artifact-listing-#{other.id}")
    refute html =~ matching.source_ref

    view
    |> form("#artifact-catalog-filter-form", filters: %{q: "Browser", artifact_type: ""})
    |> render_submit()

    assert_patch(view, ~p"/artifact-catalog?q=Browser")
    assert has_element?(view, "#artifact-listing-#{matching.id}")
    refute has_element?(view, "#artifact-listing-#{other.id}")
  end

  test "operator API refuses regular users and records operator publications", %{conn: conn} do
    user = github_user("artifact-catalog-regular-user")
    browser = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

    forbidden = post(browser, ~p"/api/operator/artifact-listings", listing_attributes())
    assert json_response(forbidden, 403) == %{"error" => "operator_required"}

    grant_operator(user)

    created =
      build_conn()
      |> Plug.Test.init_test_session(%{"user_id" => user.id})
      |> post(~p"/api/operator/artifact-listings", listing_attributes())

    assert %{"listing" => %{"id" => id, "publication_receipt_ref" => receipt_ref}} =
             json_response(created, 201)

    assert {:ok, listing} = ArtifactCatalog.get_public_listing(id)
    assert listing.publication_receipt_ref == receipt_ref
  end
end
