defmodule OpenAgents.Forum.LegacySurfaceTest do
  @moduledoc """
  #23: what the cutover from the legacy forum has to keep true.

  Two claims, both of which used to live only in prose. The forge no longer
  reads the legacy mirror, and a link written against the legacy surface still
  lands on the topic it named.
  """

  use OpenAgents.DataCase, async: true

  alias OpenAgents.Forum

  # The mirror's own identifiers. The bare word also appears in seeded
  # changelog copy about an unrelated governance chain, which is prose rather
  # than a dependency, so the pattern names the database, its role, and its
  # Cloud SQL instance instead.
  @mirror ~r/khala_sync_prod|khala_app|khala-sync-pg/i

  # The one-time import. It is a Mix task: it needs `FORUM_IMPORT_*` in the
  # environment, nothing in the application calls it, and `Mix` is not loaded
  # in a release, so it cannot run on a served node.
  @import_task "lib/mix/tasks/openagents.forum.import.ex"

  describe "the legacy mirror" do
    test "is named nowhere the running application can reach" do
      offenders =
        (Path.wildcard("lib/**/*.{ex,exs}") ++ Path.wildcard("config/**/*.exs"))
        |> Enum.reject(&(&1 == @import_task))
        |> Enum.filter(&Regex.match?(@mirror, File.read!(&1)))

      assert offenders == [],
             "the legacy forum mirror is still named outside the one-time import task: " <>
               Enum.join(offenders, ", ")
    end

    test "is named in the import task, which is a Mix task and not application code" do
      source = File.read!(@import_task)

      assert Regex.match?(@mirror, source),
             "the import task no longer names its source; move this test or delete it"

      assert source =~ "use Mix.Task"
    end

    test "is not a repository this application starts" do
      assert Application.get_env(:openagents, :ecto_repos) == [OpenAgents.Repo]
    end
  end

  describe "legacy links" do
    setup do
      # The import wrote each legacy row's own UUID into the primary key, which
      # is what makes the redirect map an identity rather than a table.
      legacy_board = "1b4f0e98-4b1f-4a2a-9c3d-000000000023"
      legacy_topic = "2c5f1e98-4b1f-4a2a-9c3d-000000000023"

      board =
        Repo.insert!(%Forum.Forum{
          id: legacy_board,
          slug: "product-promises",
          title: "Product promises",
          visibility: "public",
          discoverability: "listed"
        })

      topic =
        Repo.insert!(%Forum.Topic{
          id: legacy_topic,
          forum_id: board.id,
          idempotency_key: "legacy-topic-#{legacy_topic}",
          slug: "what-the-forge-promises",
          title: "What the forge promises",
          actor_ref: "agent:user_0123abcd",
          actor_display_name: "Artanis",
          state: "open",
          pin_state: "normal",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

      %{board: board, topic: topic}
    end

    test "a legacy topic id resolves to the topic it named", %{topic: topic} do
      assert {:ok, resolved} = Forum.fetch_readable_topic(topic.id, [])
      assert resolved.title == "What the forge promises"
    end

    test "a legacy board slug resolves to the board it named", %{board: board} do
      assert {:ok, resolved} = Forum.fetch_readable_forum_by_slug(board.slug, [])
      assert resolved.id == board.id
    end

    test "an anonymous reader resolves both, with no operator scope", %{
      board: board,
      topic: topic
    } do
      assert {:ok, _board} = Forum.fetch_readable_forum_by_slug(board.slug, operator?: false)
      assert {:ok, _topic} = Forum.fetch_readable_topic(topic.id, operator?: false)
    end
  end
end
