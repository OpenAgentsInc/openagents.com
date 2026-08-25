defmodule OpenAgents.Memories.RetrievalTest do
  @moduledoc """
  The swappable retrieval boundary, and which backend a deployment actually
  gets.

  The distinction this file exists to keep honest is between the target and the
  stand-in. The embedding backend is the one the workspace retrieval rule asks
  for, and it is off unless a deployment configures it; the full-text backend
  is what runs otherwise, and it is a stand-in rather than an answer. A change
  that quietly made the stand-in the permanent backend, or that let the target
  fail a turn instead of degrading, should turn this red.
  """
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Memories
  alias OpenAgents.Memories.{Recall, Retrieval}
  alias OpenAgents.Memories.Retrieval.{Lexical, Semantic}
  alias OpenAgents.Plugins.EmbeddingsErrorProvider

  defp account(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()
    login = "retrieval-" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 12))

    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  defp configure(overrides) do
    previous = Application.get_env(:openagents, :memory_recall)

    Application.put_env(
      :openagents,
      :memory_recall,
      Keyword.merge(previous || [], overrides)
    )

    on_exit(fn -> Application.put_env(:openagents, :memory_recall, previous) end)
  end

  describe "backend selection" do
    test "a deployment with no embedding credential runs the stand-in" do
      refute Semantic.available?()
      assert Retrieval.backend() == Lexical
    end

    test "the target backend takes over once it is configured" do
      configure(embeddings_enabled: true, provider: OpenAgents.Memories.SynonymEmbeddingsProvider)

      assert Semantic.available?()
      assert Retrieval.backend() == Semantic
    end
  end

  describe "the target backend" do
    setup do
      configure(
        embeddings_enabled: true,
        provider: OpenAgents.Memories.SynonymEmbeddingsProvider,
        dimensions: 3
      )

      :ok
    end

    # The whole reason the embedding backend is the target: these two sentences
    # share no word, and the stand-in scores them at zero.
    test "connects a learned memory to a turn that shares no word with it" do
      user = account("semantic-learned")

      {:ok, _related} =
        Memories.create(user, %{
          "body" => "This project uses pnpm for packages.",
          "bucket" => "learned"
        })

      {:ok, _unrelated} =
        Memories.create(user, %{
          "body" => "Ship the release from the production branch.",
          "bucket" => "learned"
        })

      %Recall{memories: recalled, backend: backend} =
        Memories.recall(user, "install the dependencies")

      assert backend == :semantic
      assert Enum.map(recalled, & &1.body) == ["This project uses pnpm for packages."]
    end

    test "the same pair is missed by the stand-in, which is why it is the stand-in" do
      user = account("semantic-versus-lexical")

      {:ok, memory} =
        Memories.create(user, %{
          "body" => "This project uses pnpm for packages.",
          "bucket" => "learned"
        })

      assert {:ok, scores} = Lexical.score(user.id, "install the dependencies", [memory])
      assert scores == %{}
    end
  end

  describe "degrading" do
    test "a provider that errors falls back to the stand-in rather than failing" do
      configure(embeddings_enabled: true, provider: EmbeddingsErrorProvider)

      user = account("semantic-error")

      {:ok, _memory} = Memories.create(user, %{"body" => "Deploy with the pnpm command."})

      %Recall{memories: recalled, backend: backend} = Memories.recall(user, "deploy the project")

      assert backend == :lexical
      assert Enum.map(recalled, & &1.body) == ["Deploy with the pnpm command."]
    end

    test "a memory written before the rail was on is still recalled through the stand-in" do
      user = account("semantic-unembedded")

      # Written with embeddings off, so the row carries no vector.
      {:ok, memory} = Memories.create(user, %{"body" => "Deploy with the pnpm command."})
      assert memory.embedding == nil

      configure(embeddings_enabled: true, provider: OpenAgents.Memories.SynonymEmbeddingsProvider)

      %Recall{memories: recalled} = Memories.recall(user, "deploy the project")

      assert Enum.map(recalled, & &1.body) == ["Deploy with the pnpm command."]
    end

    test "an empty candidate set is answered, not queried" do
      assert {:lexical, [], _floor} = Retrieval.rank(Ecto.UUID.generate(), "anything", [])
    end
  end

  describe "the write path" do
    test "stores the embedding and the model it was written under" do
      configure(embeddings_enabled: true, provider: OpenAgents.Memories.SynonymEmbeddingsProvider)

      user = account("semantic-write")

      {:ok, memory} = Memories.create(user, %{"body" => "This project uses pnpm."})

      assert is_list(memory.embedding)
      assert memory.embedding_model == Semantic.model_id()
    end

    test "a provider failure still writes the memory" do
      configure(embeddings_enabled: true, provider: EmbeddingsErrorProvider)

      user = account("semantic-write-failure")

      assert {:ok, memory} = Memories.create(user, %{"body" => "Written anyway."})
      assert memory.embedding == nil
    end
  end
end
