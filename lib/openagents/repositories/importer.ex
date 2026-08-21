defmodule OpenAgents.Repositories.Importer do
  @moduledoc "Copies one accepted GitHub ref snapshot into the durable forge WAL."

  require Logger

  alias OpenAgents.{Accounts, Audit, GitHubOAuth, Repo}
  alias OpenAgents.Forge.{Repos, Sync, WAL}
  alias OpenAgents.Repositories.{Repository, RepositoryImport}

  @maximum_append_attempts 3
  @default_import_timeout_ms 6 * 60 * 60 * 1_000
  @default_maximum_bundle_bytes 20 * 1_024 * 1_024 * 1_024

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
             :ok <-
               bounded_copy(
                 repository,
                 running_import,
                 source_url,
                 credential,
                 temporary_directory,
                 options
               ) do
          mark_completed!(running_import)
          :ok
        end
      rescue
        _error ->
          log_stage(repository, running_import, "import", "failed", :import_exception)
          {:error, :import_failed}
      catch
        _kind, _reason ->
          log_stage(repository, running_import, "import", "failed", :import_exception)
          {:error, :import_failed}
      after
        File.rm_rf(temporary_directory)
      end

    case result do
      :ok ->
        log_stage(repository, running_import, "import", "completed")
        :ok

      {:error, reason} ->
        log_stage(repository, running_import, "import", "failed", reason)
        mark_failed!(running_import, error_code(reason))
        {:error, reason}
    end
  end

  defp bounded_copy(
         repository,
         repository_import,
         source_url,
         credential,
         temporary_directory,
         options
       ) do
    timeout_ms =
      Keyword.get(
        options,
        :timeout_ms,
        Application.get_env(
          :openagents,
          :repository_import_timeout_ms,
          @default_import_timeout_ms
        )
      )

    if is_integer(timeout_ms) and timeout_ms > 0 do
      task =
        Task.async(fn ->
          copy_snapshot(
            repository,
            repository_import,
            source_url,
            credential,
            temporary_directory,
            options
          )
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          {:error, :import_failed}

        nil ->
          _result = Task.shutdown(task, :brutal_kill)
          {:error, :import_timeout}
      end
    else
      {:error, :import_timeout}
    end
  end

  defp copy_snapshot(
         repository,
         repository_import,
         source_url,
         credential,
         temporary_directory,
         options
       ) do
    with :ok <-
           import_stage(repository, repository_import, "prepare_workspace", fn ->
             with :ok <- File.mkdir_p(temporary_directory),
                  :ok <- File.chmod(temporary_directory, 0o700) do
               :ok
             end
           end),
         {:ok, source_repository} <-
           import_stage(repository, repository_import, "initialize_source", fn ->
             initialize_source(temporary_directory)
           end),
         :ok <-
           import_stage(repository, repository_import, "fetch_source", fn ->
             fetch_source(
               source_repository,
               source_url,
               credential,
               temporary_directory,
               options
             )
           end),
         {:ok, refs} <-
           import_stage(repository, repository_import, "verify_snapshot", fn ->
             verify_snapshot(source_repository, repository_import)
           end),
         {:ok, payload, format, payload_bytes, shallow_boundaries} <-
           import_stage(repository, repository_import, "create_payload", fn ->
             create_payload(source_repository, refs, temporary_directory)
           end),
         :ok <- log_payload_ready(repository, repository_import, payload_bytes),
         :ok <-
           import_stage(repository, repository_import, "append_wal", fn ->
             append_import(
               repository,
               repository_import,
               payload,
               format,
               refs,
               shallow_boundaries,
               0
             )
           end),
         :ok <-
           import_stage(repository, repository_import, "materialize_cache", fn ->
             Sync.ensure_fresh(repository.storage_key, repository.default_branch)
           end) do
      :ok
    end
  end

  defp source_access(repository, repository_import, options) do
    case Keyword.get(options, :source_url) do
      source_url when is_binary(source_url) ->
        credential = Keyword.get(options, :source_credential)

        cond do
          Path.type(source_url) != :absolute -> {:error, :invalid_source_url}
          is_nil(credential) or is_binary(credential) -> {:ok, source_url, credential}
          true -> {:error, :invalid_source_credential}
        end

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

  defp fetch_source(source_repository, source_url, credential, temporary_directory, options) do
    with {:ok, environment} <- credential_environment(credential, temporary_directory) do
      git_runner = Keyword.get(options, :git_runner, &Repos.git/3)

      args = [
        "-c",
        "credential.helper=",
        "fetch",
        "--force",
        "--prune",
        "--depth=1",
        "--no-tags",
        "--no-recurse-submodules",
        source_url,
        "+refs/heads/*:refs/heads/*",
        "+refs/tags/*:refs/tags/*"
      ]

      case git_runner.(source_repository, args, env: environment) do
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
    do: {:ok, "", "empty_import", 0, []}

  defp create_payload(source_repository, _refs, temporary_directory) do
    bundle_path = Path.join(temporary_directory, "snapshot.bundle")

    case Repos.git(source_repository, ["bundle", "create", bundle_path, "--all"]) do
      {_output, 0} ->
        case File.stat(bundle_path) do
          {:ok, %File.Stat{type: :regular, size: size}} ->
            if size <= maximum_bundle_bytes() do
              {:ok, {:file, bundle_path}, "git_bundle", size,
               shallow_boundaries(source_repository)}
            else
              {:error, :import_too_large}
            end

          {:ok, _not_regular} ->
            {:error, :bundle_unavailable}

          {:error, _reason} ->
            {:error, :bundle_unavailable}
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
         _shallow_boundaries,
         attempt
       )
       when attempt >= @maximum_append_attempts,
       do: {:error, :wal_cas_conflict}

  defp append_import(
         repository,
         repository_import,
         payload,
         format,
         refs,
         shallow_boundaries,
         attempt
       ) do
    result =
      :global.trans({{:repository_import, repository.storage_key}, self()}, fn ->
        append_import_once(
          repository,
          repository_import,
          payload,
          format,
          refs,
          shallow_boundaries
        )
      end)

    case result do
      {:error, :cas_conflict} ->
        append_import(
          repository,
          repository_import,
          payload,
          format,
          refs,
          shallow_boundaries,
          attempt + 1
        )

      other ->
        other
    end
  end

  defp append_import_once(
         repository,
         repository_import,
         payload,
         format,
         refs,
         shallow_boundaries
       ) do
    with {:ok, expected, index} <- read_or_create_index(repository.storage_key),
         :missing <- import_entry(index, repository_import.id),
         true <- WAL.refs(index) == %{} or {:error, :destination_not_empty},
         seq = WAL.next_seq(index),
         {:ok, object} <- put_payload(repository.storage_key, seq, payload),
         entry = %{
           "seq" => seq,
           "object" => object,
           "format" => format,
           "import_id" => repository_import.id,
           "refs" => refs,
           "shallow" => shallow_boundaries,
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

    Repo.transaction(fn ->
      running =
        repository_import
        |> RepositoryImport.transition_changeset(%{
          state: "running",
          attempt_count: repository_import.attempt_count + 1,
          error_code: nil,
          started_at: repository_import.started_at || now,
          completed_at: nil
        })
        |> Repo.update!()

      audit_import_transition!(running)
      running
    end)
    |> elem(1)
    |> announce()
  end

  defp mark_completed!(repository_import) do
    Repo.transaction(fn ->
      completed =
        repository_import
        |> RepositoryImport.transition_changeset(%{
          state: "completed",
          attempt_count: repository_import.attempt_count,
          error_code: nil,
          started_at: repository_import.started_at,
          completed_at: DateTime.utc_now()
        })
        |> Repo.update!()

      audit_import_transition!(completed)
      completed
    end)
    |> elem(1)
    |> announce()
  end

  defp mark_failed!(repository_import, error_code) do
    Repo.transaction(fn ->
      failed =
        fresh_import!(repository_import.id)
        |> RepositoryImport.transition_changeset(%{
          state: "failed",
          attempt_count: repository_import.attempt_count,
          error_code: error_code,
          started_at: repository_import.started_at,
          completed_at: nil
        })
        |> Repo.update!()

      audit_import_transition!(failed)
      failed
    end)
    |> elem(1)
    |> announce()
  end

  # Every import transition is announced on the repository's own topic once the
  # transaction holding it has committed. A copy from GitHub is the longest
  # thing a repository does before it is usable, and the browser has no other
  # way to learn that it moved from queued to copying.
  defp announce(%RepositoryImport{} = repository_import) do
    OpenAgents.Repositories.broadcast_provisioning(repository_import.repository_id)
    repository_import
  end

  defp audit_import_transition!(repository_import) do
    metadata =
      %{
        "attempt_count" => repository_import.attempt_count,
        "state" => repository_import.state
      }
      |> maybe_put_error(repository_import.error_code)

    Audit.record!(
      "repository.import.#{repository_import.state}",
      :system,
      "repository_import",
      repository_import.id,
      repository_id: repository_import.repository_id,
      metadata: metadata
    )
  end

  defp maybe_put_error(metadata, nil), do: metadata
  defp maybe_put_error(metadata, error_code), do: Map.put(metadata, "error_code", error_code)

  defp error_code(:source_changed), do: "source_changed"
  defp error_code(:github_scope_required), do: "github_scope_required"
  defp error_code(:github_token_missing), do: "github_connection_required"
  defp error_code(:import_timeout), do: "import_timeout"
  defp error_code(:import_too_large), do: "import_too_large"
  defp error_code(_reason), do: "import_failed"

  defp import_stage(repository, repository_import, stage, operation) do
    log_stage(repository, repository_import, stage, "started")

    case operation.() do
      :ok = result ->
        log_stage(repository, repository_import, stage, "completed")
        result

      {:ok, _value} = result ->
        log_stage(repository, repository_import, stage, "completed")
        result

      {:ok, _value, _metadata} = result ->
        log_stage(repository, repository_import, stage, "completed")
        result

      {:ok, _value, _metadata, _measurement} = result ->
        log_stage(repository, repository_import, stage, "completed")
        result

      {:ok, _value, _metadata, _measurement, _details} = result ->
        log_stage(repository, repository_import, stage, "completed")
        result

      {:error, reason} = result ->
        log_stage(repository, repository_import, stage, "failed", reason)
        result
    end
  end

  defp log_stage(repository, repository_import, stage, state, reason \\ nil) do
    message =
      "repository_import_stage" <>
        " repository_id=#{repository.id}" <>
        " repository_import_id=#{repository_import.id}" <>
        " stage=#{stage}" <>
        " state=#{state}" <>
        diagnostic_error(reason)

    if state == "failed", do: Logger.warning(message), else: Logger.info(message)
  end

  defp diagnostic_error(nil), do: ""

  defp diagnostic_error(reason) when is_atom(reason),
    do: " error_code=#{reason |> Atom.to_string() |> String.slice(0, 80)}"

  defp diagnostic_error(_reason), do: " error_code=unexpected_error"

  defp put_payload(storage_key, seq, {:file, path}),
    do: WAL.put_entry_file(storage_key, seq, path)

  defp put_payload(storage_key, seq, payload) when is_binary(payload),
    do: WAL.put_entry(storage_key, seq, payload)

  defp log_payload_ready(repository, repository_import, bytes) do
    Logger.info(
      "repository_import_payload" <>
        " repository_id=#{repository.id}" <>
        " repository_import_id=#{repository_import.id}" <>
        " bytes=#{bytes}" <>
        " storage=streamed"
    )

    :ok
  end

  defp maximum_bundle_bytes do
    case Application.get_env(
           :openagents,
           :repository_import_max_bundle_bytes,
           @default_maximum_bundle_bytes
         ) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_maximum_bundle_bytes
    end
  end

  defp shallow_boundaries(source_repository) do
    source_repository
    |> Path.join("shallow")
    |> File.read()
    |> case do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{40,64}\z/, &1))
        |> Enum.uniq()
        |> Enum.sort()

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "read shallow boundaries",
          path: source_repository
    end
  end

  defp temporary_directory(import_id) do
    root = Application.get_env(:openagents, :repository_import_temp_dir, System.tmp_dir!())
    Path.join(root, "openagents-import-#{import_id}-#{System.unique_integer([:positive])}")
  end
end
