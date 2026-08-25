defmodule OpenAgentsWeb.MemoryControllerTest do
  @moduledoc """
  The three routes that write, read, and remove an account's memories.

  This file is also the export proof `OpenAgents.DataRights.ExportInventory`
  names for the `:memory` family: the list route is how an account takes its
  memories with it, so the test that it returns the account's own rows — and
  only its own — is what that portability claim rests on.
  """
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Conversations
  alias OpenAgents.DataRights
  alias OpenAgents.Memories

  describe "POST /api/v1/memories" do
    test "writes a memory and returns it", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("memory-create")
        |> post(~p"/api/v1/memories", %{"body" => "I use pnpm, not npm."})
        |> json_response(201)

      assert %{"memory" => memory} = body
      assert memory["body"] == "I use pnpm, not npm."
      assert memory["bucket"] == "user"
      assert memory["superseded_by"] == nil
      assert is_binary(memory["id"])
      assert is_binary(memory["created_at"])
    end

    test "takes the bucket and the source the caller names", %{conn: conn} do
      memory =
        conn
        |> put_chat_api_token("memory-create-learned")
        |> post(~p"/api/v1/memories", %{
          "body" => "The suite needs a database before it boots.",
          "bucket" => "learned",
          "source_ref" => "thread:0e2f"
        })
        |> json_response(201)
        |> Map.fetch!("memory")

      assert memory["bucket"] == "learned"
      assert memory["source_ref"] == "thread:0e2f"
    end

    test "a correction supersedes rather than edits", %{conn: conn} do
      conn = put_chat_api_token(conn, "memory-supersede")

      wrong =
        conn
        |> post(~p"/api/v1/memories", %{"body" => "I use npm."})
        |> json_response(201)
        |> Map.fetch!("memory")

      right =
        conn
        |> post(~p"/api/v1/memories", %{
          "body" => "I use pnpm, not npm.",
          "supersedes" => wrong["id"]
        })
        |> json_response(201)
        |> Map.fetch!("memory")

      live = conn |> get(~p"/api/v1/memories") |> json_response(200) |> Map.fetch!("memories")
      assert Enum.map(live, & &1["id"]) == [right["id"]]

      all =
        conn
        |> get(~p"/api/v1/memories?include_superseded=true")
        |> json_response(200)
        |> Map.fetch!("memories")

      superseded = Enum.find(all, &(&1["id"] == wrong["id"]))
      assert superseded["superseded_by"] == right["id"]
    end

    test "refuses an empty body with the envelope", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("memory-invalid")
        |> post(~p"/api/v1/memories", %{"body" => ""})
        |> json_response(422)

      assert body["code"] == "validation_failed"
      assert Map.has_key?(body["errors"], "body")
    end

    test "refuses a bucket outside the vocabulary", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("memory-bucket")
        |> post(~p"/api/v1/memories", %{"body" => "Fine.", "bucket" => "system"})
        |> json_response(422)

      assert body["code"] == "validation_failed"
      assert Map.has_key?(body["errors"], "bucket")
    end

    test "refuses a supersedes that names no live memory of this account", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("memory-supersede-missing")
        |> post(~p"/api/v1/memories", %{
          "body" => "Corrected.",
          "supersedes" => "00000000-0000-4000-8000-000000000001"
        })
        |> json_response(422)

      assert body["code"] == "validation_failed"
      assert Map.has_key?(body["errors"], "supersedes")
    end

    test "refuses a write past the ceiling with its own code", %{conn: conn} do
      previous = Application.get_env(:openagents, :memory_recall) || []

      Application.put_env(
        :openagents,
        :memory_recall,
        Keyword.merge(previous, maximum_live_memories: 1)
      )

      on_exit(fn -> Application.put_env(:openagents, :memory_recall, previous) end)

      conn = put_chat_api_token(conn, "memory-quota")

      assert conn |> post(~p"/api/v1/memories", %{"body" => "One."}) |> json_response(201)

      body = conn |> post(~p"/api/v1/memories", %{"body" => "Two."}) |> json_response(429)
      assert body["code"] == "memory_quota_reached"
    end
  end

  describe "GET /api/v1/memories" do
    test "lists the account's memories and never another account's", %{conn: conn} do
      mine = put_chat_api_token(conn, "memory-list-mine")
      theirs = put_chat_api_token(conn, "memory-list-theirs")

      post(mine, ~p"/api/v1/memories", %{"body" => "Mine."})
      post(theirs, ~p"/api/v1/memories", %{"body" => "Theirs."})

      bodies =
        mine
        |> get(~p"/api/v1/memories")
        |> json_response(200)
        |> Map.fetch!("memories")
        |> Enum.map(& &1["body"])

      assert bodies == ["Mine."]
    end

    test "narrows to one bucket", %{conn: conn} do
      conn = put_chat_api_token(conn, "memory-list-bucket")

      post(conn, ~p"/api/v1/memories", %{"body" => "Explicit."})
      post(conn, ~p"/api/v1/memories", %{"body" => "Learned.", "bucket" => "learned"})

      bodies =
        conn
        |> get(~p"/api/v1/memories?bucket=learned")
        |> json_response(200)
        |> Map.fetch!("memories")
        |> Enum.map(& &1["body"])

      assert bodies == ["Learned."]
    end
  end

  describe "DELETE /api/v1/memories/:id" do
    test "removes the account's own memory", %{conn: conn} do
      conn = put_chat_api_token(conn, "memory-delete")

      memory =
        conn
        |> post(~p"/api/v1/memories", %{"body" => "Temporary."})
        |> json_response(201)
        |> Map.fetch!("memory")

      assert conn |> delete(~p"/api/v1/memories/#{memory["id"]}") |> json_response(200)

      assert conn |> get(~p"/api/v1/memories") |> json_response(200) |> Map.fetch!("memories") ==
               []
    end

    test "refuses another account's memory as absent", %{conn: conn} do
      mine = put_chat_api_token(conn, "memory-delete-mine")
      theirs = put_chat_api_token(conn, "memory-delete-theirs")

      memory =
        mine
        |> post(~p"/api/v1/memories", %{"body" => "Mine."})
        |> json_response(201)
        |> Map.fetch!("memory")

      body = theirs |> delete(~p"/api/v1/memories/#{memory["id"]}") |> json_response(404)
      assert body["code"] == "not_found"
    end
  end

  describe "authority" do
    test "every route refuses a caller with no credential", %{conn: conn} do
      assert conn |> post(~p"/api/v1/memories", %{"body" => "x"}) |> json_response(401)
      assert conn |> get(~p"/api/v1/memories") |> json_response(401)

      assert conn
             |> delete(~p"/api/v1/memories/00000000-0000-4000-8000-000000000001")
             |> json_response(401)
    end

    # The lane is `chat:account`. A credential minted for another scope is not
    # a credential for this surface, however valid it is elsewhere.
    test "refuses a credential scoped for something else", %{conn: conn} do
      body =
        conn
        |> put_box_api_token("memory-wrong-scope")
        |> get(~p"/api/v1/memories")
        |> json_response(401)

      assert body["code"] == "unauthenticated"
    end
  end

  # DATA-004. Memories key on the account row, and the account row is
  # deliberately retained through a product-data deletion, so the visitor
  # cascade does not reach them. They have to be removed explicitly, and this
  # is the test that says so.
  describe "DATA-004" do
    test "deleting product data removes the account's memories" do
      user = github_user("memory-data-rights")

      {:ok, _memory} = Memories.create(user, %{"body" => "Remember this."})

      {:ok, conversation} = Conversations.ensure_conversation(user)
      owner = Conversations.get_conversation_owner!(conversation)

      assert {:ok, :deleted} = DataRights.delete(user, owner, conversation)
      assert Memories.list(user) == []
    end
  end
end
