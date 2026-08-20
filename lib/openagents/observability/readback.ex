defmodule OpenAgents.Observability.Readback do
  @moduledoc "Bounded aggregate read-back over authoritative receipts, without private content."

  alias OpenAgents.Repo

  @planes %{
    "provider" => {"turn_provider_steps", "status"},
    "tool" => {"turn_tool_steps", "status"},
    "memory" => {"profile_memory_records", "status"},
    "module" => {"module_route_receipts", "status"},
    "collective" => {"collective_candidates", "status"},
    "evaluation" => {"program_lifecycle_artifacts", "stage"}
  }

  @spec snapshot() :: map()
  def snapshot do
    voice_config = OpenAgents.Voice.Config.current!()

    %{
      schema: "openagents.observability.readback.v1",
      captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      persona_id: OpenAgents.Persona.current!().id,
      persona_digest: OpenAgents.Persona.current!().digest,
      text_model_id: Application.fetch_env!(:openagents, :openai_model),
      voice_model_id: voice_config.model,
      voice_artifact_id: "sarah.voice.openai.#{voice_config.voice}.v1",
      module_registry_digest: OpenAgents.Tools.Registry.current!().digest,
      planes: Map.new(@planes, fn {plane, source} -> {plane, status_counts(source)} end),
      integrity: integrity_counts()
    }
  end

  defp status_counts({table, column}) do
    sql =
      "SELECT #{column}, count(*)::bigint FROM #{table} GROUP BY #{column} ORDER BY #{column} LIMIT 32"

    sql
    |> Repo.query!([])
    |> Map.fetch!(:rows)
    |> Map.new(fn [status, count] -> {status, count} end)
  end

  defp integrity_counts do
    %{
      "cross_scope_private_leakage" =>
        scalar("""
        SELECT count(*)::bigint FROM collective_candidates c
        JOIN collective_consent_receipts r ON r.id=c.consent_receipt_id
        WHERE c.visitor_id<>r.visitor_id OR c.source_scope_digest<>r.source_scope_digest
        """),
      "missing_collective_consent" =>
        scalar("""
        SELECT count(*)::bigint FROM collective_candidates c
        LEFT JOIN collective_consent_receipts r ON r.id=c.consent_receipt_id
        WHERE r.id IS NULL
        """),
      "missing_turn_provenance" =>
        scalar("""
        SELECT count(*)::bigint FROM turn_receipts
        WHERE status<>'captured' AND
          (persona_id IS NULL OR persona_digest IS NULL OR role_id IS NULL OR
           role_digest IS NULL OR instruction_digest IS NULL OR input_digest IS NULL)
        """),
      "missing_executor_disclosure" =>
        scalar("""
        SELECT count(*)::bigint FROM turn_tool_steps
        WHERE status NOT IN ('requested','running') AND
          (executor_id IS NULL OR executor_id='' OR executor_disclosure IS NULL OR executor_disclosure='')
        """),
      "failed_attribution_reconciliation" =>
        scalar("""
        SELECT count(*)::bigint FROM turn_tool_steps s
        LEFT JOIN compensation_events e ON e.tool_step_id=s.id
        WHERE s.status='succeeded' AND s.billable=true AND e.id IS NULL
        """),
      "stuck_turns" =>
        scalar("""
        SELECT count(*)::bigint FROM turns
        WHERE status IN ('queued','running') AND updated_at < now() - interval '5 minutes'
        """),
      "stuck_tool_steps" =>
        scalar("""
        SELECT count(*)::bigint FROM turn_tool_steps
        WHERE status IN ('requested','running') AND inserted_at < now() - interval '5 minutes'
        """)
    }
  end

  defp scalar(sql) do
    %{rows: [[value]]} = Repo.query!(sql, [])
    value
  end
end
