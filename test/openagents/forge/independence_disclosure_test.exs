defmodule OpenAgents.Forge.IndependenceDisclosureTest do
  @moduledoc """
  EXIT-006. A gap the forge records privately and reports publicly as health is
  a gap the forge has hidden.

  The disclosure is only worth publishing if it cannot drift from the thing it
  describes, so every assertion here derives its expectation from the source of
  truth rather than restating it: the export section is compared against
  `OpenAgents.DataRights.ExportInventory`, and the verification section is
  compared against the configured anchor source rather than a constant.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.DataRights.ExportInventory
  alias OpenAgents.Forge.Anchor
  alias OpenAgents.Forge.Independence

  # Every string the disclosure may contain. A repository path, an account id,
  # a node name, or a commit sha reaching this projection fails here, which is
  # STATUS-001's rule applied to the one section that talks about the operator.
  @vocabulary ~w(
    openagents.forge_independence.v1
    docs/forge-operator-independence.md
    single_operator
    tamper_evident
    tamper_evident_published
    /.well-known/openagents-forge-anchor.json
    portable partial blocked not_user_data
  )

  # The projection is briefly cached so anonymous traffic cannot become an rpc
  # storm. A test that publishes an anchor would otherwise leave that state in
  # the cache for whichever test runs next.
  setup do
    :persistent_term.erase({OpenAgents.NetworkStatus, :cache})
    on_exit(fn -> :persistent_term.erase({OpenAgents.NetworkStatus, :cache}) end)
    :ok
  end

  describe "the disclosure derives from the ledger" do
    test "every gap the export ledger records is published, and no other" do
      recorded =
        (ExportInventory.with_status(:partial) ++ ExportInventory.with_status(:blocked))
        |> Enum.map(&%{"family" => Atom.to_string(&1.family), "issue" => &1.issue})
        |> Enum.sort_by(& &1["family"])

      published =
        Independence.projection()["export"]["gaps"]
        |> Enum.map(&Map.take(&1, ["family", "issue"]))

      assert published == recorded
    end

    test "the family counts are the ledger's own counts" do
      export = Independence.projection()["export"]

      assert export["families"] == length(ExportInventory.entries())

      for status <- [:portable, :partial, :blocked, :not_user_data] do
        assert export[Atom.to_string(status)] == length(ExportInventory.with_status(status))
      end
    end
  end

  describe "degraded is decided, not asserted" do
    test "an unpublished anchor is enough on its own to report degraded" do
      projection = Independence.projection()

      refute projection["verification"]["anchor_published"]
      assert projection["verification"]["property"] == "tamper_evident"
      assert projection["verification"]["issue"] == 168
      assert projection["degraded"]
      assert Independence.degraded?()
    end

    test "a plaintext store is enough on its own to report degraded" do
      # #178 closed the export half of the private-data axis. If closing it
      # had quietly taken that axis out of the disjunction, a forge with
      # plaintext columns would report itself independent as soon as the
      # verification axis cleared. Every other axis is handed in clean here,
      # which `degraded?/3` exists for: the projection alone cannot show that
      # this axis is load-bearing, because the others are never clean.
      clean_export = %{"gaps" => []}
      clean_verification = %{"anchor_published" => true, "anchor_witnessed" => true}
      private_data = Independence.projection()["private_data"]

      refute Independence.degraded?(clean_export, clean_verification, %{
               private_data
               | "encrypted_at_rest" => true,
                 "operator_reads_source" => false
             })

      assert Independence.degraded?(clean_export, clean_verification, private_data)
    end

    # The publication state is read from the anchors that exist, not from a
    # flag someone can set, so this test publishes a real one.
    test "publishing an anchor changes the verification claim" do
      {:ok, _anchor} = Anchor.publish()

      verification = Independence.projection()["verification"]

      assert verification["anchor_published"]
      assert verification["property"] == "tamper_evident_published"
      assert verification["anchor"] == Anchor.path()
    end

    # The whole point of ADR 0008: the operator serves the anchor, so
    # publishing it does not make it evidence against the operator. A
    # disclosure that closed the verification axis on publication alone would
    # be claiming exactly what the anchor cannot show.
    test "a published anchor is still not witnessed, and still reports degraded" do
      {:ok, _anchor} = Anchor.publish()

      projection = Independence.projection()

      assert projection["verification"]["anchor_published"]
      refute projection["verification"]["anchor_witnessed"]
      assert projection["verification"]["issue"] == 151
      assert projection["degraded"]
      assert Independence.degraded?()
    end

    test "the export encryption and the plaintext store are published together" do
      # #178 decided that an export can be encrypted to a recipient-held key
      # and that the columns behind it stay plaintext. Publishing the first
      # without the second would let a reader conclude the operator cannot
      # read an export, so the second is what `operator_reads_source` says
      # and it is derived from the first rather than asserted beside it.
      private_data = Independence.projection()["private_data"]

      assert private_data["export_recipient_encryption"]
      refute private_data["encrypted_at_rest"]
      assert private_data["operator_reads_source"]
      assert private_data["access_controlled"]
      assert private_data["issue"] == 193
    end

    test "the export encryption claim is read from the route rather than asserted" do
      # The claim is true exactly while `OpenAgentsWeb.DataController` was
      # compiled against the module that encrypts. Nothing here restates it,
      # so removing the encryption removes the claim in the same commit.
      {:ok, {module, [imports: imports]}} =
        :beam_lib.chunks(:code.which(OpenAgentsWeb.DataController), [:imports])

      assert module == OpenAgentsWeb.DataController

      assert OpenAgents.DataRights.Age in Enum.map(imports, &elem(&1, 0)),
             "EXIT-006 derives `export_recipient_encryption` from this call. If the export " <>
               "route stopped encrypting, the disclosure must stop claiming it."
    end

    test "the account export still takes the account and nothing else" do
      # `access_controlled` is derived from this shape, which is the whole
      # access-control claim for this document: no parameter can widen it.
      assert function_exported?(OpenAgents.DataRights.AccountExport, :build, 1)
      refute function_exported?(OpenAgents.DataRights.AccountExport, :build, 2)
    end
  end

  describe "the disclosure carries no content" do
    test "every string in the projection is a family name, a status, or fixed vocabulary" do
      families = Enum.map(ExportInventory.entries(), &Atom.to_string(&1.family))
      allowed = MapSet.new(@vocabulary ++ families)

      for value <- strings(Independence.projection()) do
        assert MapSet.member?(allowed, value),
               "the independence disclosure published #{inspect(value)}, which is neither a " <>
                 "ledger family nor fixed vocabulary. STATUS-001 keeps content out of this page."
      end
    end
  end

  describe "the surfaces publish it" do
    test "GET /api/status carries the disclosure", %{conn: conn} do
      body = conn |> get(~p"/api/status") |> json_response(200)

      assert body["independence"]["schema"] == "openagents.forge_independence.v1"
      assert body["independence"]["degraded"]
      assert body["independence"]["operator"]["model"] == "single_operator"
      refute body["independence"]["operator"]["mirror_is_authority"]
    end

    test "the status page names the degraded state and every gap", %{conn: conn} do
      conn = put_req_header(conn, "accept", "text/html")
      {:ok, view, _html} = live(conn, ~p"/status")

      assert has_element?(view, "#status-independence")
      assert view |> element("#status-independence-summary") |> render() =~ "degraded"
      assert has_element?(view, "#status-independence-verification")
      assert has_element?(view, "#status-independence-private-data")
      refute has_element?(view, "#status-independence-anchor-witness")

      rendered = render(view)

      for entry <- ExportInventory.with_status(:partial) do
        assert rendered =~ Atom.to_string(entry.family)
      end
    end

    test "a published anchor is named on the page and still called unwitnessed",
         %{conn: conn} do
      Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})
      {:ok, _anchor} = Anchor.publish()
      :persistent_term.erase({OpenAgents.NetworkStatus, :cache})

      conn = put_req_header(conn, "accept", "text/html")
      {:ok, view, _html} = live(conn, ~p"/status")

      assert view |> element("#status-independence-verification") |> render() =~ Anchor.path()

      assert view |> element("#status-independence-anchor-witness") |> render() =~
               "witnessed by nobody"

      assert view |> element("#status-independence-summary") |> render() =~ "degraded"
    end
  end

  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_binary(value), do: [value]
  defp strings(_other), do: []
end
