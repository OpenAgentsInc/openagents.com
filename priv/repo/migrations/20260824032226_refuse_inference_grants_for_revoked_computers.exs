defmodule OpenAgents.Repo.Migrations.RefuseInferenceGrantsForRevokedComputers do
  @moduledoc """
  A grant is authority to spend the owner's account at the inference proxy, and
  `inference_grants.machine_id` names the computer it was minted for. Revoking
  that computer left the grant `active`: its plaintext token was already on the
  computer, and it kept buying tokens until its own budget or `expires_at`
  closed it. `OpenAgents.Inference.revoke_active_for_machine/1` closes the
  outstanding ones. This closes the window underneath that.

  Between the moment a revocation decides a computer is gone and the moment it
  commits, a delegation can mint a new grant for the same computer. The sweep
  has already run; the new row is not in it. So the fence is here rather than
  only in Elixir: every insert that names a computer reads that computer's row
  under `FOR SHARE` and refuses unless it is active.

  `FOR SHARE` is what makes the ordering total. A revocation's
  `UPDATE machines SET status = 'revoked'` takes `FOR NO KEY UPDATE`, which
  conflicts with it, so the two transactions cannot overlap on that row. Either
  the mint commits first and the revocation's sweep finds its grant, or the
  revocation commits first and the mint blocks, re-reads `revoked`, and raises.
  The foreign key's own `FOR KEY SHARE` does not conflict with an ordinary
  update and would not have served.

  The guard is a trigger rather than a `CHECK` because it reads another table,
  and it covers every writer rather than the one call site a source scan finds.
  `OpenAgents.Inference.mint/1` performs the same read first, so an ordinary
  caller gets `{:error, :machine_revoked}` instead of a `Postgrex.Error`.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION inference_grants_refuse_revoked_computer()
    RETURNS trigger AS $$
    DECLARE
      computer_status text;
    BEGIN
      IF NEW.machine_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT status INTO computer_status
      FROM machines
      WHERE id = NEW.machine_id
      FOR SHARE;

      IF computer_status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION
          'inference_grants cannot name computer % (%)',
          NEW.machine_id, COALESCE(computer_status, 'absent');
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER inference_grants_refuse_revoked_computer
    BEFORE INSERT ON inference_grants
    FOR EACH ROW EXECUTE FUNCTION inference_grants_refuse_revoked_computer();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS inference_grants_refuse_revoked_computer ON inference_grants;"
    )

    execute("DROP FUNCTION IF EXISTS inference_grants_refuse_revoked_computer();")
  end
end
