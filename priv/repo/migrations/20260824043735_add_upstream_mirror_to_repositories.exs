defmodule OpenAgents.Repo.Migrations.AddUpstreamMirrorToRepositories do
  use Ecto.Migration

  # An upstream mirror is a repository whose content comes from a public
  # source this forge does not own. `upstream_url` names that source and is
  # the whole distinction: NULL is an owned repository, non-NULL is a mirror.
  #
  # `upstream_license` travels with it, and the check constraint is why a
  # mirror can never be silent about its license: the two columns are NULL
  # together or set together, so recording an upstream without recording what
  # it is licensed under is not a representable state. An upstream that
  # publishes no license records the literal "none", which is a statement
  # rather than an omission.
  def change do
    alter table(:repositories) do
      add :upstream_url, :string
      add :upstream_license, :string
    end

    create constraint(:repositories, :repositories_upstream_mirror_check,
             check: "(upstream_url IS NULL) = (upstream_license IS NULL)"
           )

    create index(:repositories, [:upstream_url], where: "upstream_url IS NOT NULL")
  end
end
