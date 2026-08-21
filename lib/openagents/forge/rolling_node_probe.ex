defmodule OpenAgents.Forge.RollingNodeProbe do
  @moduledoc """
  Returns the bounded node-local facts required by rolling replacement.

  The infrastructure provider calls this module over Erlang distribution. The
  response contains identity and readiness state only. It never includes a
  database address, credential, request, or application content.
  """

  @doc "Return node health and Ra quorum for an expected fleet size."
  def status(expected_fleet_size)
      when is_integer(expected_fleet_size) and expected_fleet_size > 0 do
    status(expected_fleet_size, nil, nil)
  end

  @doc "Return node health against an operator-approved rolling image identity."
  def status(expected_fleet_size, expected_sha, expected_image_digest)
      when is_integer(expected_fleet_size) and expected_fleet_size > 0 do
    report = OpenAgents.Cluster.local_report()
    ra_members = OpenAgents.Cluster.Ra.members()

    candidate_image? =
      report["revision"] == expected_sha and report["image_digest"] == expected_image_digest

    boot_converged? = report["boot_converged"] == true or candidate_image?

    candidate_ready? =
      candidate_image? and
        report["deployment_ready"] == true and
        report["admission_ready"] == true

    database_ready? = database_ready?()

    %{
      member: true,
      ready: (report["ready"] == true or candidate_ready?) and database_ready?,
      boot_converged: boot_converged?,
      database_ready: database_ready?,
      sha: report["revision"],
      image_digest: report["image_digest"],
      ra_quorum: length(ra_members) * 2 > expected_fleet_size
    }
  end

  defp database_ready? do
    match?({:ok, _result}, OpenAgents.Repo.query("SELECT 1"))
  rescue
    _error -> false
  end
end
