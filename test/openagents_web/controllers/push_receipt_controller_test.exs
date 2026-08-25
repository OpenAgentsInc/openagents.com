defmodule OpenAgentsWeb.PushReceiptControllerTest do
  @moduledoc """
  EXIT-001 and EXIT-005, stage 2. `git push` prints the pusher the WAL
  sequence and chain link their push produced; this is where they read it
  again when the terminal is gone.

  What the route can and cannot settle is asserted as carefully as it is
  written. It publishes the WAL's own record rather than the derived
  `forge_pushes` rows, so a pusher comparing a retained link against what this
  serves is comparing against the same record `Verification.verify/2` reads.
  It does not turn a re-fetch into evidence: an operator who rewrote the log
  would serve the rewritten link here too, which is why the link the pusher
  kept is the anchor and this is a convenience.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.ApiTokens
  alias OpenAgents.Forge.WAL
  alias OpenAgents.Repositories

  setup %{conn: conn} do
    base = Path.join(System.tmp_dir!(), "push-receipts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_wal_dir, base)

    on_exit(fn ->
      Application.put_env(:openagents, :forge_wal_dir, previous)
      File.rm_rf(base)
    end)

    owner = github_user("push-receipt-owner", "receipt-owner")

    {:ok, public, :created} =
      Repositories.create_user_repository(
        owner,
        %{name: "open-work", visibility: "public"},
        "push-receipt-public"
      )

    {:ok, private, :created} =
      Repositories.create_user_repository(
        owner,
        %{name: "closed-work", visibility: "private"},
        "push-receipt-private"
      )

    public = ready!(public)
    private = ready!(private)

    {:ok, _credential, token} =
      ApiTokens.create(owner, %{name: "push receipt reader", scopes: ["forge:write"]})

    %{
      conn: conn,
      owner_conn: put_req_header(conn, "authorization", "Bearer " <> token),
      public: public,
      private: private
    }
  end

  describe "the receipts a pusher can re-read" do
    test "the list carries the sequence, the ref change, and the chain link", %{
      conn: conn,
      public: repository
    } do
      entries = seed_wal!(repository.storage_key, 3)

      body =
        conn
        |> get(~p"/api/v1/repos/receipt-owner/open-work/pushes")
        |> json_response(200)

      assert body["repo"] == "receipt-owner/open-work"
      assert body["chained_from"] == 0

      # Newest first, so the head — the link worth remembering — is first.
      assert Enum.map(body["pushes"], & &1["wal_seq"]) == [2, 1, 0]

      assert Enum.map(body["pushes"], & &1["link"]) ==
               entries |> Enum.map(&WAL.entry_link/1) |> Enum.reverse()

      head = hd(body["pushes"])
      assert head["principal"] == "user:pusher"
      assert head["refs"]["refs/heads/main"]["new"] == sha(2)
      assert head["refs"]["refs/heads/main"]["old"] == sha(1)
    end

    test "one receipt is fetchable by the sequence the push printed", %{
      conn: conn,
      public: repository
    } do
      entries = seed_wal!(repository.storage_key, 2)
      expected = Enum.at(entries, 1)

      body =
        conn
        |> get(~p"/api/v1/repos/receipt-owner/open-work/pushes/1")
        |> json_response(200)

      assert body["wal_seq"] == 1
      assert body["link"] == WAL.entry_link(expected)
      assert body["pushed_at"] == expected["pushed_at"]
    end

    test "the published link is the link the verifier recomputes", %{
      conn: conn,
      public: repository
    } do
      entries = seed_wal!(repository.storage_key, 2)
      head = List.last(entries)

      body =
        conn
        |> get(~p"/api/v1/repos/receipt-owner/open-work/pushes/1")
        |> json_response(200)

      assert body["link"] == WAL.entry_link(head)

      # The route is a projection of the WAL, so an anchor built from what it
      # served raises no anchor finding against the log it came from, and one
      # link short of it does. (These entries name objects no repository
      # holds, so the other findings are expected here and irrelevant.)
      assert anchor_codes(repository, %{seq: body["wal_seq"], link: body["link"]}) == []

      assert anchor_codes(repository, %{seq: body["wal_seq"], link: String.duplicate("0", 64)}) ==
               ["anchor_mismatch"]
    end

    test "a repository nobody has pushed to has an empty record, not a missing one", %{
      conn: conn,
      public: repository
    } do
      assert {:error, :not_found} = WAL.read_index(repository.storage_key)

      body =
        conn
        |> get(~p"/api/v1/repos/receipt-owner/open-work/pushes")
        |> json_response(200)

      assert body["pushes"] == []
      assert body["chained_from"] == nil
    end

    test "a sequence the log does not have is not found", %{conn: conn, public: repository} do
      seed_wal!(repository.storage_key, 1)

      assert conn
             |> get(~p"/api/v1/repos/receipt-owner/open-work/pushes/9")
             |> json_response(404)
    end
  end

  describe "who may read them" do
    test "a private repository refuses an anonymous reader", %{conn: conn, private: repository} do
      seed_wal!(repository.storage_key, 1)

      assert conn
             |> get(~p"/api/v1/repos/receipt-owner/closed-work/pushes")
             |> json_response(404)
    end

    test "a private repository serves its own member", %{
      owner_conn: conn,
      private: repository
    } do
      seed_wal!(repository.storage_key, 1)

      body =
        conn
        |> get(~p"/api/v1/repos/receipt-owner/closed-work/pushes")
        |> json_response(200)

      assert Enum.map(body["pushes"], & &1["wal_seq"]) == [0]
    end
  end

  defp anchor_codes(repository, anchor) do
    {_ok_or_error, report} =
      OpenAgents.Forge.Verification.verify(repository.storage_key, anchor: anchor)

    report.findings
    |> Enum.map(& &1.code)
    |> Enum.filter(&String.starts_with?(&1, "anchor_"))
  end

  defp ready!(repository) do
    repository
    |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
    |> OpenAgents.Repo.update!()
  end

  # Entries shaped exactly as `OpenAgents.Forge.Pushes.persist/4` writes them,
  # appended through `WAL.append_entry/2` so they carry real chain links.
  defp seed_wal!(storage_key, count) do
    index =
      Enum.reduce(0..(count - 1), WAL.new_index(), fn seq, index ->
        {:ok, object} = WAL.put_entry(storage_key, seq, "pack-#{seq}")

        WAL.append_entry(index, %{
          "seq" => seq,
          "object" => object,
          "format" => "receive_pack",
          "refs" => %{"refs/heads/main" => sha(seq)},
          "principal" => "user:pusher",
          "pushed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
      end)

    {:ok, _generation} = WAL.cas_index(storage_key, :none, index)
    WAL.entries(index)
  end

  defp sha(seq), do: String.duplicate(Integer.to_string(seq), 40)
end
