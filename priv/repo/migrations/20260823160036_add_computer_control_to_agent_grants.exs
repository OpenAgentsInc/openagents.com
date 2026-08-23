defmodule OpenAgents.Repo.Migrations.AddComputerControlToAgentGrants do
  use Ecto.Migration

  def up do
    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check:
               "scopes <@ ARRAY['chat:account', 'forge:write', 'deployments:write', 'box:control', 'computer:control']::varchar[]"
           )

    alter table(:agent_box_control_grants) do
      add :target_kind, :string, null: true
    end

    execute "UPDATE agent_box_control_grants SET target_kind = 'box' WHERE target_kind IS NULL"

    alter table(:agent_box_control_grants) do
      modify :target_kind, :string, null: false, default: "box"
    end

    drop constraint(
           :agent_box_control_grants,
           :agent_box_control_grants_scope_check
         )

    create constraint(
             :agent_box_control_grants,
             :agent_box_control_grants_scope_check,
             check:
               "(target_kind = 'box' AND scope = 'box:control') OR " <>
                 "(target_kind = 'computer' AND scope = 'computer:control')"
           )

    create constraint(
             :agent_box_control_grants,
             :agent_box_control_grants_target_kind_check,
             check: "target_kind IN ('box', 'computer')"
           )
  end

  def down do
    case repo().query!(
           "SELECT 1 FROM agent_box_control_grants WHERE target_kind = 'computer' LIMIT 1"
         ).rows do
      [[1]] ->
        raise "cannot roll back computer control while computer grants exist"

      _ ->
        :ok
    end

    drop constraint(
           :agent_box_control_grants,
           :agent_box_control_grants_target_kind_check
         )

    drop constraint(
           :agent_box_control_grants,
           :agent_box_control_grants_scope_check
         )

    create constraint(
             :agent_box_control_grants,
             :agent_box_control_grants_scope_check,
             check: "scope = 'box:control'"
           )

    alter table(:agent_box_control_grants) do
      remove :target_kind
    end

    drop constraint(:api_tokens, :api_tokens_scopes_allowed)

    create constraint(:api_tokens, :api_tokens_scopes_allowed,
             check:
               "scopes <@ ARRAY['chat:account', 'forge:write', 'deployments:write', 'box:control']::varchar[]"
           )
  end
end
