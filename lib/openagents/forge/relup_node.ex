defmodule OpenAgents.Forge.RelupNode do
  @moduledoc """
  Performs one node's verified OTP release-handler transaction.

  The immutable artifact remains in a digest-addressed cache. Before every
  unpack attempt, this module restores the release tar to the path consumed by
  `release_handler`, so an interrupted install can retry from the same bytes.
  """

  alias OpenAgents.ReleaseState

  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @version_pattern ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z/
  @maximum_artifact_bytes 536_870_912

  @doc "Cache and stage an immutable release artifact."
  def stage(request, opts \\ []) do
    with :ok <- validate_request(request),
         true <-
           byte_size(request.artifact_bytes) <= @maximum_artifact_bytes or
             {:error, :artifact_too_large},
         true <-
           digest(request.artifact_bytes) == request.artifact_digest or
             {:error, :artifact_digest_mismatch},
         :ok <- ensure_release_directories(opts),
         :ok <- persist_cache(request, opts),
         :ok <- restage(request, opts) do
      {:ok, %{"phase" => "staged", "artifact_digest" => request.artifact_digest}}
    end
  end

  @doc "Verify that both cached and staged artifacts match the request."
  def verify_stage(request, opts \\ []) do
    with :ok <- verify_file(cache_path(request, opts), request.artifact_digest),
         :ok <- verify_file(stage_path(request, opts), request.artifact_digest) do
      {:ok, %{"phase" => "stage_verified"}}
    end
  end

  @doc "Restore the consumable tar and unpack it when needed."
  def unpack(request, opts \\ []) do
    with :ok <- restage(request, opts) do
      if release_known?(request.to_version, opts) do
        {:ok, %{"phase" => "unpacked", "restaged" => true}}
      else
        expected_version = to_charlist(request.to_version)

        case handler_call(opts, :unpack_release, [to_charlist(release_basename(request))]) do
          {:ok, ^expected_version} ->
            {:ok, %{"phase" => "unpacked", "restaged" => true}}

          {:error, reason} ->
            {:error, {:unpack_failed, safe_code(reason)}}

          _other ->
            {:error, :unexpected_unpack_result}
        end
      end
    end
  end

  @doc "Generate runtime configuration and preflight the relup."
  def check_install(request, opts \\ []) do
    with :ok <- generate_config(request.to_version, opts) do
      expected_from = to_charlist(request.from_version)

      case handler_call(opts, :check_install_release, [to_charlist(request.to_version)]) do
        {:ok, ^expected_from, _description} ->
          {:ok, %{"phase" => "checked"}}

        {:error, reason} ->
          {:error, {:check_failed, safe_code(reason)}}

        _other ->
          {:error, :unexpected_check_result}
      end
    end
  end

  @doc "Install the unpacked candidate without making it permanent."
  def install(request, opts \\ []) do
    expected_from = to_charlist(request.from_version)

    case handler_call(opts, :install_release, [to_charlist(request.to_version)]) do
      {:ok, ^expected_from, _description} ->
        {:ok, %{"phase" => "installed"}}

      {:continue_after_restart, ^expected_from, _description} ->
        {:ok, %{"phase" => "restart_required"}}

      {:error, reason} ->
        {:error, {:install_failed, safe_code(reason)}}

      _other ->
        {:error, :unexpected_install_result}
    end
  end

  @doc "Verify the running release, application health, and migrated state."
  def verify(request, permanence \\ :current, opts \\ []) do
    expected_status = if permanence == :permanent, do: :permanent, else: :current

    with true <-
           release_status(request.to_version, opts) == expected_status or
             {:error, :release_status_mismatch},
         %{"ready" => true} <- health_report(opts),
         %{schema_version: schema} <- state_snapshot(opts),
         true <- schema == request.to_state_version or {:error, :state_version_mismatch} do
      {:ok, %{"phase" => "verified", "permanence" => to_string(permanence)}}
    else
      {:error, reason} -> {:error, reason}
      _unhealthy -> {:error, :health_check_failed}
    end
  end

  @doc "Make the candidate release permanent."
  def make_permanent(request, opts \\ []) do
    case handler_call(opts, :make_permanent, [to_charlist(request.to_version)]) do
      :ok -> {:ok, %{"phase" => "permanent"}}
      {:error, reason} -> {:error, {:make_permanent_failed, safe_code(reason)}}
      _other -> {:error, :unexpected_make_permanent_result}
    end
  end

  @doc "Install and verify the reverse relup, then restore permanence."
  def reverse(request, opts \\ []) do
    with {:ok, _result} <- reverse_install(request, opts),
         :ok <- verify_reverse_health(request, opts),
         :ok <- reverse_permanent(request, opts),
         true <-
           release_status(request.from_version, opts) == :permanent or
             {:error, :reverse_not_permanent} do
      {:ok, %{"phase" => "reversed", "restored" => true}}
    end
  end

  defp reverse_install(request, opts) do
    from_version = to_charlist(request.from_version)
    to_version = to_charlist(request.to_version)

    case handler_call(opts, :install_release, [to_charlist(request.from_version)]) do
      {:ok, ^from_version, _description} ->
        {:ok, :installed}

      {:ok, ^to_version, _description} ->
        {:ok, :installed}

      {:error, reason} ->
        {:error, {:reverse_install_failed, safe_code(reason)}}

      _other ->
        {:error, :unexpected_reverse_install_result}
    end
  end

  defp verify_reverse_health(request, opts) do
    with true <-
           release_status(request.from_version, opts) in [:current, :permanent] or
             {:error, :reverse_status_mismatch},
         %{"ready" => true} <- health_report(opts),
         %{schema_version: schema} <- state_snapshot(opts),
         true <- schema == request.from_state_version or {:error, :reverse_state_version_mismatch} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _unhealthy -> {:error, :reverse_health_check_failed}
    end
  end

  defp reverse_permanent(request, opts) do
    case handler_call(opts, :make_permanent, [to_charlist(request.from_version)]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:reverse_permanent_failed, safe_code(reason)}}
      _other -> {:error, :unexpected_reverse_permanent_result}
    end
  end

  defp validate_request(request) when is_map(request) do
    cond do
      Map.get(request, :release_name) != "openagents" -> {:error, :invalid_release_name}
      not version?(Map.get(request, :from_version)) -> {:error, :invalid_from_version}
      not version?(Map.get(request, :to_version)) -> {:error, :invalid_to_version}
      not is_binary(Map.get(request, :artifact_bytes)) -> {:error, :invalid_artifact}
      not digest?(Map.get(request, :artifact_digest)) -> {:error, :invalid_artifact_digest}
      Map.get(request, :from_state_version) not in [1, 2] -> {:error, :invalid_from_state_version}
      Map.get(request, :to_state_version) not in [1, 2] -> {:error, :invalid_to_state_version}
      true -> :ok
    end
  end

  defp validate_request(_request), do: {:error, :invalid_request}

  defp version?(version), do: is_binary(version) and Regex.match?(@version_pattern, version)
  defp digest?(value), do: is_binary(value) and Regex.match?(@digest_pattern, value)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp ensure_release_directories(opts) do
    File.mkdir_p!(cache_dir(opts))
    File.mkdir_p!(releases_dir(opts))
    :ok
  rescue
    _error -> {:error, :release_directory_unavailable}
  end

  defp persist_cache(request, opts) do
    path = cache_path(request, opts)

    case verify_file(path, request.artifact_digest) do
      :ok ->
        :ok

      {:error, :missing_artifact} ->
        atomic_write(path, request.artifact_bytes)

      {:error, _reason} ->
        {:error, :cached_artifact_conflict}
    end
  end

  defp restage(request, opts) do
    with :ok <- verify_file(cache_path(request, opts), request.artifact_digest),
         {:ok, bytes} <- File.read(cache_path(request, opts)),
         :ok <- atomic_write(stage_path(request, opts), bytes),
         :ok <- verify_file(stage_path(request, opts), request.artifact_digest) do
      :ok
    end
  end

  defp atomic_write(path, bytes) do
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, bytes, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:artifact_write_failed, safe_code(reason)}}
    end
  end

  defp verify_file(path, expected_digest) do
    case File.read(path) do
      {:ok, bytes} ->
        if digest(bytes) == expected_digest, do: :ok, else: {:error, :artifact_digest_mismatch}

      {:error, :enoent} ->
        {:error, :missing_artifact}

      {:error, _reason} ->
        {:error, :artifact_unreadable}
    end
  end

  defp release_known?(version, opts), do: release_status(version, opts) != nil

  defp release_status(version, opts) do
    opts
    |> handler_call(:which_releases, [])
    |> Enum.find_value(fn
      {_name, found_version, _applications, status}
      when status in [:unpacked, :current, :permanent, :old] ->
        if to_string(found_version) == version, do: status

      _other ->
        nil
    end)
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp handler_call(opts, function, arguments) do
    apply(Keyword.get(opts, :release_handler, :release_handler), function, arguments)
  end

  defp generate_config(version, opts) do
    case Keyword.get(opts, :generate_config, &Castle.generate/1).(version) do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_generation_failed, safe_code(reason)}}
      _other -> :ok
    end
  rescue
    _error -> {:error, :config_generation_failed}
  end

  defp health_report(opts), do: Keyword.get(opts, :health, &OpenAgents.Cluster.local_report/0).()
  defp state_snapshot(opts), do: Keyword.get(opts, :state, &ReleaseState.snapshot/0).()

  defp release_basename(request), do: "#{request.release_name}-#{request.to_version}"

  defp root(opts),
    do: Keyword.get_lazy(opts, :release_root, fn -> to_string(:code.root_dir()) end)

  defp releases_dir(opts), do: Path.join(root(opts), "releases")
  defp cache_dir(opts), do: Path.join(releases_dir(opts), ".openagents-relup-cache")

  defp cache_path(request, opts),
    do: Path.join(cache_dir(opts), "#{request.artifact_digest}.tar.gz")

  defp stage_path(request, opts),
    do: Path.join(releases_dir(opts), "#{release_basename(request)}.tar.gz")

  defp safe_code(reason), do: OpenAgents.OperationalLog.code(reason)
end
