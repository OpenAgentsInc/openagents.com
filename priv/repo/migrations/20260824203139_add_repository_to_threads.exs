defmodule OpenAgents.Repo.Migrations.AddRepositoryToThreads do
  @moduledoc """
  Record the repository a thread concerns, when its opener names one.

  Nullable and bounded, with no foreign key: a thread may concern a repository
  the forge does not host, so the column records the opener's `owner/name`
  string rather than referencing the repositories table. `openagents coder
  --resume` filters its picker on this field instead of parsing the objective
  sentence the CLI itself composed (issue #210).
  """

  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :repository, :text
    end

    create constraint(:threads, :threads_repository_bound_check,
             check: "repository IS NULL OR octet_length(repository) BETWEEN 1 AND 200"
           )
  end
end
