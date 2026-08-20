defmodule OpenAgents.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :openagents

  @migration_lock_id 42_424_242

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &run_migrations/1)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc "Rewrap retained GitHub grants with the configured active vault key."
  def rotate_github_tokens do
    load_app()

    for repo <- repos() do
      {:ok, rotated, _apps} =
        Ecto.Migrator.with_repo(repo, fn _repo -> OpenAgents.Accounts.rotate_github_tokens!() end)

      IO.puts("github_tokens_rotated=#{rotated}")
    end
  end

  defp run_migrations(repo) do
    # Acquire a session-level advisory lock so only one release migrates at a
    # time, then run the standard Ecto migration set.
    Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_lock($1)", [@migration_lock_id])

    try do
      Ecto.Migrator.run(repo, :up, all: true)
    after
      Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_unlock($1)", [@migration_lock_id])
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
