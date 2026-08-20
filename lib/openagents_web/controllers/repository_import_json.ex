defmodule OpenAgentsWeb.RepositoryImportJSON do
  @moduledoc "JSON projections for one-time repository imports."

  alias OpenAgents.Repositories.RepositoryImport

  def import(%RepositoryImport{} = repository_import) do
    %{
      "id" => repository_import.id,
      "provider" => repository_import.provider,
      "source_full_name" => repository_import.source_full_name,
      "source_default_branch" => repository_import.source_default_branch,
      "source_head_sha" => repository_import.source_head_sha,
      "source_ref_digest" => repository_import.source_ref_digest,
      "state" => repository_import.state,
      "attempt_count" => repository_import.attempt_count,
      "error_code" => repository_import.error_code,
      "lfs_warning" => repository_import.source_uses_lfs,
      "started_at" => iso8601(repository_import.started_at),
      "completed_at" => iso8601(repository_import.completed_at),
      "created_at" => iso8601(repository_import.inserted_at),
      "updated_at" => iso8601(repository_import.updated_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)
end
