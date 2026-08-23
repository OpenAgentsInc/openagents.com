defmodule Mix.Tasks.Openagents.Forum.Import do
  @moduledoc """
  One-time import of the legacy Effect forum from `khala_sync_prod`.

  Reads forums, topics, posts, and post bodies over a Postgres connection
  (typically the Cloud SQL Auth Proxy on localhost), preserves legacy UUID
  ids so old URLs keep working, and is idempotent: rows whose ids already
  exist are skipped, never duplicated.

  The source connection comes from `FORUM_IMPORT_DATABASE_URL`, or defaults
  to postgres at `127.0.0.1:15432` as user `khala_app` against database
  `khala_sync_prod`, with the password from `FORUM_IMPORT_PASSWORD`.

  The destination is the application repository. `FORUM_IMPORT_DESTINATION_DATABASE_URL`
  points the run at a different database — the production one, reached through
  the Cloud SQL Auth Proxy on localhost — without changing the application's
  own configuration. The report names both endpoints as `host:port/database`,
  so a recorded run always says where it landed.

  ## Run

      mix openagents.forum.import

      FORUM_IMPORT_DATABASE_URL=... FORUM_IMPORT_PASSWORD=... mix openagents.forum.import

      FORUM_IMPORT_DATABASE_URL=... \\
        FORUM_IMPORT_DESTINATION_DATABASE_URL=... \\
        mix openagents.forum.import
  """

  use Mix.Task

  alias OpenAgents.Forum.BoardDescriptions
  alias OpenAgents.Repo

  @shortdoc "Import the legacy forum data from khala_sync_prod"
  # Configuration only. The task starts the destination pool itself and needs
  # nothing else of the application, so an import into production does not
  # depend on a full local boot and its unrelated runtime secrets.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    destination = start_destination!()

    try do
      import_forum(destination)
    after
      stop_destination(destination)
    end
  end

  defp import_forum(destination) do
    source_opts = postgrex_opts()
    Mix.shell().info("source:      #{endpoint(source_opts)}")
    Mix.shell().info("destination: #{destination.description}")

    {:ok, pid} = Postgrex.start_link(source_opts)

    {:ok, forums} = Postgrex.query(pid, "SELECT * FROM forum_forums", [])
    {:ok, topics} = Postgrex.query(pid, "SELECT * FROM forum_topics", [])
    {:ok, posts} = Postgrex.query(pid, "SELECT * FROM forum_posts", [])
    {:ok, bodies} = Postgrex.query(pid, "SELECT post_id, body_text FROM forum_post_bodies", [])

    GenServer.stop(pid)

    forums = to_maps(forums)
    topics = to_maps(topics)
    posts = to_maps(posts)

    body_by_post_id =
      bodies.rows
      |> Enum.map(fn [post_id, body_text] -> {post_id, body_text} end)
      |> Map.new()

    # content_ref values look like "content.forum.post.<uuid>"; bodies are
    # keyed by the bare post id.
    # Some legacy rows point at parents or quotes that no longer exist; those
    # references are dropped rather than failing the whole import.
    _source_post_ids =
      MapSet.new(posts, fn row ->
        case Ecto.UUID.cast(row.id) do
          {:ok, id} -> Ecto.UUID.dump!(id)
          :error -> nil
        end
      end)
      |> MapSet.delete(nil)

    post_body =
      fn content_ref ->
        case content_ref &&
               content_ref =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i do
          true ->
            Regex.run(
              ~r/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i,
              content_ref
            )
            |> List.last()
            |> then(&Map.get(body_by_post_id, &1))

          _ ->
            nil
        end
      end

    existing_forum_ids = existing_ids("forum_forums")
    existing_topic_ids = existing_ids("forum_topics")
    existing_post_ids = existing_ids("forum_posts")

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    forum_counts =
      insert_rows(
        "forum_forums",
        Enum.map(forums, &forum_entry(&1, now)),
        existing_forum_ids
      )

    topic_counts =
      insert_rows(
        "forum_topics",
        Enum.map(topics, &topic_entry(&1, now)),
        existing_topic_ids
      )

    entries =
      Enum.flat_map(posts, &post_entry(&1, post_body, now))

    post_counts =
      insert_rows(
        "forum_posts",
        Enum.map(entries, &unlinked/1),
        existing_post_ids
      )

    # Link parents and quotes after every row exists, so a post that
    # references a later sibling cannot violate the foreign key.
    linked = link_post_references(entries)
    counted = refresh_counters()

    verify(destination, topics, posts, forum_counts, topic_counts, post_counts, linked, counted)
  end

  # A post is inserted without its references and linked afterwards.
  defp unlinked(entry), do: %{entry | parent_post_id: nil, quote_post_id: nil}

  ## Destination — the database this run writes to

  # The task owns its destination pool. Without an override it uses the
  # application's own repository configuration; with one it writes to the
  # named database instead. Either way the pool is anonymous and this process
  # is pointed at it, so the run writes exactly where the report says.
  defp start_destination! do
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)
    {:ok, _apps} = Application.ensure_all_started(:postgrex)

    opts =
      case System.get_env("FORUM_IMPORT_DESTINATION_DATABASE_URL") do
        nil ->
          Repo.config()

        url ->
          opts = Keyword.put(url_opts(url), :pool_size, 2)

          # Replace the repository configuration outright rather than merging
          # over it. A merge leaves the application's own `socket_dir` in
          # place, and Postgrex prefers a unix socket to the host and port it
          # was given, so the run would write to a database the report does
          # not name -- the exact confusion this task exists to end.
          Application.put_env(:openagents, Repo, opts)
          opts
      end

    {:ok, pid} = Repo.start_link(Keyword.put(opts, :name, nil))
    Repo.put_dynamic_repo(pid)

    %{pid: pid, description: connected_endpoint(opts)}
  end

  defp stop_destination(%{pid: pid}) do
    Repo.put_dynamic_repo(Repo)
    Supervisor.stop(pid)
  end

  # The user and database the server itself reports, asked of the live
  # connection rather than read back from the options we hoped it used, plus
  # the address this run dialed. A record that names the wrong database is
  # worse than one that names none.
  defp connected_endpoint(opts) do
    %Postgrex.Result{rows: [[user, database]]} =
      Repo.query!("SELECT current_user, current_database()", [])

    "#{user}@#{database} through #{endpoint(opts)}"
  end

  # Credential-free identity of a connection: never the password.
  defp endpoint(opts) do
    host = opts[:hostname] || opts[:socket_dir] || "unknown-host"
    port = opts[:port]
    database = opts[:database] || "unknown-database"

    case port do
      nil -> "#{host}/#{database}"
      port -> "#{host}:#{port}/#{database}"
    end
  end

  defp to_maps(%Postgrex.Result{columns: columns, rows: rows}) do
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end

  ## Row mapping

  defp forum_entry(row, now) do
    %{
      id: uuid!(row.id),
      slug: row.slug,
      title: row.title,
      description: description(row.slug, row[:description_ref]),
      visibility: row.visibility,
      discoverability: row.discoverability,
      locked: row.locked in [1, true],
      # Boards timestamp as `inserted_at`; topics and posts keep the legacy
      # `created_at` name. Writing the wrong one fails the whole insert.
      inserted_at: timestamp!(row.created_at, now),
      updated_at: timestamp!(row.updated_at, now)
    }
  end

  # Legacy boards store a `content.*` pointer, not prose, and nothing in the
  # source resolves those pointers to text. The board list renders whatever
  # lands here, so a written description wins, and an unresolvable pointer is
  # dropped rather than shown to readers as "content.forum.mining.description".
  defp description(slug, reference) do
    BoardDescriptions.fetch(slug) || resolved_reference(reference)
  end

  defp resolved_reference(nil), do: nil

  defp resolved_reference(reference) do
    if String.starts_with?(reference, "content."), do: nil, else: reference
  end

  defp topic_entry(row, now) do
    actor = actor_json(row.actor_json)

    %{
      id: uuid!(row.id),
      forum_id: uuid!(row.forum_id),
      idempotency_key: row.idempotency_key,
      slug: row.slug,
      title: row.title,
      actor_ref: row.actor_ref,
      actor_display_name: actor_display_name(actor, row.actor_ref),
      actor_slug: actor[:slug],
      actor_is_agent: Map.get(actor, "isAgent", true),
      state: row.state,
      pin_state: normalize_pin_state(row.pin_state),
      post_count: row.post_count,
      first_post_id: optional_uuid(row.first_post_id),
      latest_post_id: optional_uuid(row.latest_post_id),
      archived_at: optional_timestamp(row.archived_at),
      created_at: timestamp!(row.created_at, now),
      updated_at: timestamp!(row.updated_at, now)
    }
  end

  defp post_entry(row, post_body, now) do
    case post_body.(row.content_ref) do
      nil ->
        Mix.shell().error(
          "forum_posts #{row.id}: no body for content_ref #{row.content_ref}, skipped"
        )

        []

      body_text ->
        actor = actor_json(row.actor_json)

        [
          %{
            id: uuid!(row.id),
            topic_id: uuid!(row.topic_id),
            idempotency_key: row.idempotency_key,
            post_number: row.post_number,
            body_text: body_text,
            content_kind: "markdown",
            actor_ref: row.actor_ref,
            actor_display_name: actor_display_name(actor, row.actor_ref),
            actor_slug: actor[:slug],
            actor_is_agent: Map.get(actor, "isAgent", true),
            # The legacy references travel with the entry and are stripped
            # for the insert, then linked once every row exists, so a post
            # that references a later sibling cannot violate the foreign key.
            parent_post_id: optional_uuid(row.parent_post_id),
            quote_post_id: optional_uuid(row.quote_post_id),
            state: normalize_post_state(row.state),
            archived_at: optional_timestamp(row.archived_at),
            created_at: timestamp!(row.created_at, now),
            updated_at: timestamp!(row.updated_at, now)
          }
        ]
    end
  end

  defp normalize_pin_state("sticky"), do: "pinned"
  defp normalize_pin_state("pinned"), do: "pinned"
  defp normalize_pin_state(_), do: "normal"

  # Legacy post states: "edited" posts are still visible content;
  # "tombstoned" is the legacy soft delete.
  defp normalize_post_state("tombstoned"), do: "deleted"
  defp normalize_post_state("edited"), do: "visible"
  defp normalize_post_state(state), do: state

  defp actor_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp actor_json(_), do: %{}

  defp actor_display_name(actor, fallback),
    do: Map.get(actor, "displayName") || fallback

  ## Insertion — idempotent by primary key

  defp insert_rows(_table, [], _existing), do: {0, 0}

  defp insert_rows(table, entries, existing) do
    {skipped, fresh} = Enum.split_with(entries, fn e -> MapSet.member?(existing, e.id) end)

    {imported, _} = Repo.insert_all(table, fresh, on_conflict: :nothing)

    unless skipped == [] do
      Mix.shell().info("#{table}: skipping #{length(skipped)} already-present rows")
    end

    {length(entries), imported}
  end

  defp existing_ids(table) do
    Repo.query!("SELECT id FROM #{table}", [])
    |> Map.get(:rows)
    |> MapSet.new(fn [id] -> id end)
  end

  ## Verification

  defp link_post_references(entries) do
    known =
      Repo.query!("SELECT id FROM forum_posts", [])
      |> Map.get(:rows)
      |> MapSet.new(fn [id] -> id end)

    Enum.reduce(entries, 0, fn entry, linked ->
      parent =
        resolvable_uuid(entry.parent_post_id && Ecto.UUID.load!(entry.parent_post_id), known)

      quote_id =
        resolvable_uuid(entry.quote_post_id && Ecto.UUID.load!(entry.quote_post_id), known)

      if parent || quote_id do
        # The guard makes a second run a no-op instead of rewriting every
        # reference to the value it already holds.
        result =
          Repo.query!(
            """
            UPDATE forum_posts
            SET parent_post_id = $2, quote_post_id = COALESCE($3, quote_post_id)
            WHERE id = $1
              AND (parent_post_id IS DISTINCT FROM $2
                   OR quote_post_id IS DISTINCT FROM COALESCE($3, quote_post_id))
            """,
            [entry.id, parent, quote_id]
          )

        linked + result.num_rows
      else
        linked
      end
    end)
  end

  # Boards and topics carry denormalized counters that the board list orders
  # by and both surfaces display. Nothing in the import path maintains them,
  # so an imported board would read "0 topics". They are derived from the rows
  # that actually landed, which also makes a second run a no-op.
  defp refresh_counters do
    topics =
      Repo.query!(
        """
        UPDATE forum_topics t
        SET post_count = c.posts
        FROM (SELECT topic_id, count(*) AS posts FROM forum_posts GROUP BY topic_id) c
        WHERE c.topic_id = t.id AND t.post_count IS DISTINCT FROM c.posts
        """,
        []
      )

    forums =
      Repo.query!(
        """
        UPDATE forum_forums f
        SET topic_count = c.topics, post_count = c.posts
        FROM (
          SELECT f2.id,
                 count(DISTINCT t.id) AS topics,
                 count(p.id) AS posts
          FROM forum_forums f2
          LEFT JOIN forum_topics t ON t.forum_id = f2.id
          LEFT JOIN forum_posts p ON p.topic_id = t.id
          GROUP BY f2.id
        ) c
        WHERE c.id = f.id
          AND (f.topic_count IS DISTINCT FROM c.topics
               OR f.post_count IS DISTINCT FROM c.posts)
        """,
        []
      )

    %{topics: topics.num_rows, forums: forums.num_rows}
  end

  defp verify(
         destination,
         source_topics,
         source_posts,
         forum_counts,
         topic_counts,
         post_counts,
         linked,
         counted
       ) do
    dest_topics = Repo.aggregate(from_table("forum_topics"), :count)
    dest_posts = Repo.aggregate(from_table("forum_posts"), :count)

    Mix.shell().info("""

    Forum import report
    -------------------
    destination: #{destination.description}
    forums: #{elem(forum_counts, 1)} imported of #{elem(forum_counts, 0)} source rows
    topics: #{elem(topic_counts, 1)} imported of #{length(source_topics)} source rows \
    (#{dest_topics} total in destination)
    posts:  #{elem(post_counts, 1)} imported of #{length(source_posts)} source rows \
    (#{dest_posts} total in destination)
    references linked: #{linked}
    counters refreshed: #{counted.forums} boards, #{counted.topics} topics

    Re-running skips every already-present row, so a second run reports zero imports.
    """)

    missing = length(source_topics) - elem(topic_counts, 1)

    if missing > 0 do
      Mix.shell().info("topics not imported this run: #{missing} (already present or skipped)")
    end
  end

  defp from_table(name) do
    import Ecto.Query
    from(t in name, select: count())
  end

  ## Coercion helpers

  defp uuid!(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Ecto.UUID.dump!(uuid)
      :error -> raise ArgumentError, "expected a UUID, got: #{inspect(id)}"
    end
  end

  defp resolvable_uuid(nil, _known), do: nil
  defp resolvable_uuid("", _known), do: nil

  defp resolvable_uuid(id, known) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        dumped = Ecto.UUID.dump!(uuid)

        if MapSet.member?(known, dumped), do: dumped, else: nil

      :error ->
        nil
    end
  end

  defp optional_uuid(nil), do: nil
  defp optional_uuid(""), do: nil
  defp optional_uuid(id), do: uuid!(id)

  # Source timestamps are ISO-8601 text such as "2026-07-18T15:09:38.928Z".
  defp timestamp!(text, _now) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> raise ArgumentError, "expected an ISO-8601 timestamp, got: #{inspect(text)}"
    end
  end

  defp timestamp!(_, now), do: now

  defp optional_timestamp(nil), do: nil
  defp optional_timestamp(text), do: timestamp!(text, DateTime.utc_now())

  defp postgrex_opts do
    case System.get_env("FORUM_IMPORT_DATABASE_URL") do
      nil ->
        [
          hostname: System.get_env("FORUM_IMPORT_HOST", "127.0.0.1"),
          port: String.to_integer(System.get_env("FORUM_IMPORT_PORT", "15432")),
          username: System.get_env("FORUM_IMPORT_USER", "khala_app"),
          password: System.get_env("FORUM_IMPORT_PASSWORD"),
          database: System.get_env("FORUM_IMPORT_DATABASE", "khala_sync_prod")
        ]

      url ->
        url_opts(url)
    end
  end

  defp url_opts(url) do
    %URI{host: host, port: port, userinfo: userinfo, path: path} = URI.parse(url)

    {username, password} =
      case userinfo && String.split(userinfo, ":", parts: 2) do
        [username, password] -> {username, password}
        [username] -> {username, nil}
        _absent -> {nil, nil}
      end

    [
      hostname: host,
      port: port || 5432,
      username: username,
      password: password,
      database: String.trim_leading(path || "", "/")
    ]
  end
end
