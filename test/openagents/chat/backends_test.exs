defmodule OpenAgents.Chat.BackendsTest do
  @moduledoc """
  The rules that keep one backend list from becoming three.

  Every surface that offers a backend — the turn runtime, the chat API's
  refusal, and the published contract at `GET /api/v1` — reads this module. A
  test that pins the list itself would only restate it, so these pin the
  properties a surface depends on instead.
  """
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.Backends

  test "every id is unique, and the default is one of them" do
    ids = Backends.ids()

    assert ids == Enum.uniq(ids)
    assert Backends.default_id() in ids
    assert Backends.default().id == Backends.default_id()
  end

  test "every backend resolves to a model and a callable streamer" do
    for backend <- Backends.all() do
      assert is_binary(Backends.model(backend))
      assert Backends.model(backend) != ""
      assert is_function(Backends.streamer(backend), 3)
    end
  end

  test "no preference resolves to the default, an unknown name does not" do
    assert {:ok, %{id: "glm-5.3-flash"}} = Backends.fetch(nil)
    assert {:ok, %{id: "glm-5.3-flash"}} = Backends.fetch("")

    # A caller that asked for one model and was quietly served another has no
    # way to tell, so an unknown name refuses rather than falling back.
    assert {:error, :unsupported_backend} = Backends.fetch("gpt-4")
    assert {:error, :unsupported_backend} = Backends.fetch(:gemini)
    assert {:error, :unsupported_backend} = Backends.fetch(7)
  end

  test "the catalog says the same thing the enum does" do
    catalog = Backends.catalog()

    assert Enum.map(catalog, & &1["id"]) == Backends.ids()
    assert Enum.count(catalog, & &1["default"]) == 1
    assert Enum.find(catalog, & &1["default"])["id"] == Backends.default_id()

    for entry <- catalog do
      assert is_binary(entry["label"]) and entry["label"] != ""
      assert is_binary(entry["description"]) and entry["description"] != ""
      assert is_boolean(entry["free"])
    end
  end

  test "Gemini is served on our balance, so it costs the caller nothing" do
    assert {:ok, gemini} = Backends.fetch("gemini-3.7-flash")
    assert gemini.free
    assert Backends.public(gemini)["free"]
  end
end
