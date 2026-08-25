defmodule OpenAgents.Repo.Migrations.SeedGeneralForumBoard do
  use Ecto.Migration

  # The CLI's `forum post` defaults to --board general, and the help and
  # command reference both document that default, but the imported board set
  # never included a board by that slug, so the documented command failed
  # with not_found (#244). Seeding the board makes the documented default
  # real wherever the migrations run.
  #
  # The test environment opts out (`:seed_forum_boards`): its fixtures create
  # the boards each test needs, and a pre-seeded row would collide with every
  # setup that inserts the general board itself.
  def up do
    if Application.get_env(:openagents, :seed_forum_boards, true) do
      execute """
      INSERT INTO forum_forums
        (id, slug, title, description, visibility, discoverability, locked,
         topic_count, post_count, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'general', 'General',
         'General discussion. The default board for new topics.',
         'public', 'listed', false, 0, 0, now(), now())
      ON CONFLICT (slug) DO NOTHING
      """
    end
  end

  # Only an empty general board rolls back; one that gathered topics stays.
  def down do
    execute """
    DELETE FROM forum_forums
    WHERE slug = 'general' AND topic_count = 0 AND post_count = 0
    """
  end
end
