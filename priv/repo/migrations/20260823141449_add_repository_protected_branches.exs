defmodule OpenAgents.Repo.Migrations.AddRepositoryProtectedBranches do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :protected_branches, {:array, :string}, null: false, default: []
    end
  end
end
