defmodule OpenAgents.Repositories.Importer do
  @moduledoc "Copies one accepted GitHub ref snapshot into the durable forge WAL."

  alias OpenAgents.{Accounts, GitHubOAuth, Repo}
  alias OpenAgents.Forge.{Repos, Sync, WAL}
  alias OpenAgents.Repositories.{Repository, RepositoryImport}

  @maximum_append_attempts 3

  def import(%Repository{} = repository, options \\ []) do
    repository = Repo.preload(repository, [:created_by_user, :repository_import])
    repository_import = fresh_import!(repository.repository_import.id)

    if repository_import.state == "completed" do
      Sync.ensure_fresh(repository.storage_key, repository.default_branch)
    else
      run_import(repository, repository_import, options)
    end
  end

  defp run_import(repository, repository_import, options) do
    running_import = mark_running!(repository_import)
    temporary_directory = temporary_directory(running_import.id)

    result =
      try do
        with {:ok, source_url, credential} <- source_access(repository, running_import, options),
             :ok <- File.mkdir_p(temporary_directory),
             :ok <- File.chmod(temporary_directory, 0o700),
             {:ok, source_repository} <- initialize_source(temporary_directory),
             :ok <- fetch_source(source_repository, source_url, credential, temporary_directory),
             {:ok, refs} <- verify_snapshot(source_repository, running_import),
             {:ok, payload, format} <-
               create_payload(source_repository, refs, temporary_directory),
             :ok <-
               append_import(
                 repository,
                 running_import,
                 payload,
                 format,
                 refs,
                 0
               ),
             :ok <- Sync.ensure_fresh(repository.storage_key, repository.default_branch) do
          mark_completed!(running_import)
          :ok
        end
      rescue
        _error -> {:error, :import_failed}
      catch
        _kind, _reason -> {:error, :import_failed}
      after
        File.rm_rf(temporary_directory)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        mark_failed!(running_import, error_code(reason))
        {:error, reason}
    end
  end

  defp source_access(repository, repository_import, options) do
    case Keyword.get(options, :source_url) do
      source_url when is_binary(source_url) ->
        if Path.type(source_url) == :absolute,
          do: {:ok, source_url, nil},
          else: {:error, :invalid_source_url}

      nil ->
        with true <-
               repository.created_by_user.github_token_scopes == GitHubOAuth.required_scopes() or
                 {:error, :github_scope_required},
             {:ok, credential} <- Accounts.github_token(repository.created_by_user) do
          {:ok, "https://github.com/#{repository_import.source_full_name}.git", credential}
        end
    end
  end

  defp initialize_source(temporary_directory) do
    path = Path.join(temporary_directory, "source.git")

    case System.cmd("git", ["init", "--bare", path], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, path}
      {_output, _status} -> {:error, :git_initialization_failed}
    end
  end

  defp fetch_source(source_repository, source_url, credential, temporary_directory) do
    with {:ok, environment} <- credential_environment(credential, temporary_directory) do
      args = [
        "-c",
        "credential.helper=",
        "-c",
        "credential.interactive=never",
        "fetch",
        "--force",
        "--prune",
        "--no-recurse-submodules",
        source_url,
        "+refs/heads/*:refs/heads/*",
        "+refs/tags/*:refs/tags/*"
      ]

      case Repos.git(source_repository, args, env: environment) do
        {_output, 0} -> :ok
        {_output, _status} -> {:error, :source_fetch_failed}
      end
    end
  end

  defp credential_environment(nil, _temporary_directory),
    do: {:ok, [{"GIT_TERMINAL_PROMPT", "0"}]}

  defp credential_environment(credential, temporary_directory) do
    token_path = Path.join(temporary_directory, "credential")
    askpass_path = Path.join(temporary_directory, "askpass")

    askpass = """
    #!/bin/sh
    case "$1" in
      *sername*) printf '%s\n' 'x-access-token' ;;
      *) exec /bin/cat "$OPENAGENTS_GITHUB_TOKEN_FILE" ;;
    esac
    """

    with :ok <- File.write(token_path, credential, [:binary, :exclusive]),
         :ok <- File.chmod(token_path, 0o600),
         :ok <- File.write(askpass_path, askpass, [:binary, :exclusive]),
         :ok <- File.chmod(askpass_path, 0o700) do
      {:ok,
       [
         {"GIT_ASKPASS", askpass_path},
         {"GIT_TERMINAL_PROMPT", "0"},
         {"OPENAGENTS_GITHUB_TOKEN_FILE", token_path}
       ]}
    end
  end

  defp verify_snapshot(source_repository, repository_import) do
    refs = refs(source_repository)

    cond do
      refs != repository_import.source_refs ->
        {:error, :source_changed}

      ref_digest(source_repository, refs) != repository_import.source_ref_digest ->
        {:error, :source_changed}

      true ->
        {:ok, refs}
    end
  end

  defp refs(source_repository) do
    case Repos.git(source_repository, ["for-each-ref", "--format=%(objectname) %(refname)"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [sha, name] = String.split(line, " ", parts: 2)
          {name, sha}
        end)

      {_output, _status} ->
        %{}
    end
  end

  defp ref_digest(source_repository, refs) do
    refs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {name, sha} ->
      {object_type, 0} = Repos.git(source_repository, ["cat-file", "-t", sha])
      Enum.join([name, String.trim(object_type), sha], "\0")
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp create_payload(_source_repository, refs, _temporary_directory) when map_size(refs) == 0,
    do: {:ok, "", "empty_import"}

  defp create_payload(source_repository, _refs, temporary_directory) do
    bundle_path = Path.join(temporary_directory, "snapshot.bundle")

    case Repos.git(source_repository, ["bundle", "create", bundle_path, "--all"]) do
      {_output, 0} ->
        case File.read(bundle_path) do
          {:ok, payload} -> {:ok, payload, "git_bundle"}
          {:error, _reason} -> {:error, :bundle_unavailable}
        end

      {_output, _status} ->
        {:error, :bundle_creation_failed}
    end
  end

  defp append_import(
         _repository,
         _repository_import,
         _payload,
         _format,
         _refs,
         attempt
       )
       when attempt >= @maximum_append_attempts,
       do: {:error, :wal_cas_conflict}

  defp append_import(repository, repository_import, payload, format, refs, attempt) do
    result =
      :global.trans({{:repository_import, repository.storage_key}, self()}, fn ->
        append_import_once(repository, repository_import, payload, format, refs)
      end)

    case result do
      {:error, :cas_conflict} ->
        append_import(repository, repository_import, payload, format, refs, attempt + 1)

      other ->
        other
    end
  end

  defp append_import_once(repository, repository_import, payload, format, refs) do
    with {:ok, expected, index} <- read_or_create_index(repository.storage_key),
         :missing <- import_entry(index, repository_import.id),
         true <- WAL.refs(index) == %{} or {:error, :destination_not_empty},
         seq = WAL.next_seq(index),
         {:ok, object} <- WAL.put_entry(repository.storage_key, seq, payload),
         entry = %{
           "seq" => seq,
           "object" => object,
           "format" => format,
           "import_id" => repository_import.id,
           "refs" => refs,
           "principal" => "github-import:#{repository_import.id}",
           "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
         },
         {:ok, _generation} <-
           WAL.cas_index(repository.storage_key, expected, WAL.append_entry(index, entry)) do
      :ok
    else
      {:present, entry} ->
        if entry["refs"] == refs, do: :ok, else: {:error, :import_receipt_conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_or_create_index(storage_key) do
    case WAL.read_index(storage_key) do
      {:ok, generation, index} ->
        {:ok, generation, index}

      {:error, :not_found} ->
        case WAL.cas_index(storage_key, :none, WAL.new_index()) do
          {:ok, generation} -> {:ok, generation, WAL.new_index()}
          {:error, :cas_conflict} -> read_or_create_index(storage_key)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_entry(index, import_id) do
    case Enum.find(WAL.entries(index), &(&1["import_id"] == import_id)) do
      nil -> :missing
      entry -> {:present, entry}
    end
  end

  defp fresh_import!(id), do: Repo.get!(RepositoryImport, id)

  defp mark_running!(repository_import) do
    now = DateTime.utc_now()

    repository_import
    |> RepositoryImport.transition_changeset(%{
      state: "running",
      attempt_count: repository_import.attempt_count + 1,
      error_code: nil,
      started_at: repository_import.started_at || now,
      completed_at: nil
    })
    |> Repo.update!()
  end

  defp mark_completed!(repository_import) do
    repository_import
    |> RepositoryImport.transition_changeset(%{
      state: "completed",
      attempt_count: repository_import.attempt_count,
      error_code: nil,
      started_at: repository_import.started_at,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp mark_failed!(repository_import, error_code) do
    fresh_import!(repository_import.id)
    |> RepositoryImport.transition_changeset(%{
      state: "failed",
      attempt_count: repository_import.attempt_count,
      error_code: error_code,
      started_at: repository_import.started_at,
      completed_at: nil
    })
    |> Repo.update!()
  end

  defp error_code(:source_changed), do: "source_changed"
  defp error_code(:github_scope_required), do: "github_scope_required"
  defp error_code(:github_token_missing), do: "github_connection_required"
  defp error_code(_reason), do: "import_failed"

  defp temporary_directory(import_id) do
    root = Application.get_env(:openagents, :repository_import_temp_dir, System.tmp_dir!())
    Path.join(root, "openagents-import-#{import_id}-#{System.unique_integer([:positive])}")
  end
end
