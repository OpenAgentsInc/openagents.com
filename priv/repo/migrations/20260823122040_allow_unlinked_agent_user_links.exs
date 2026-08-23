defmodule OpenAgents.Repo.Migrations.AllowUnlinkedAgentUserLinks do
  use Ecto.Migration

  def change do
    drop constraint(:agent_user_links, :agent_user_links_status_check)

    create constraint(:agent_user_links, :agent_user_links_status_check,
             check: "status IN ('pending', 'linked', 'rejected', 'unlinked')"
           )
  end
end
