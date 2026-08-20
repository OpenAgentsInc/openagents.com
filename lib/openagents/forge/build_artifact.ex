defmodule OpenAgents.Forge.BuildArtifact do
  @moduledoc """
  Reproducible forge BEAM artifact creation and atom-free verification.

  Artifacts are deterministic tar files containing one canonical
  `manifest.json` and only the added or changed normalized BEAMs. Verification
  binds the tar digest, manifest identity, entry names, sizes, module count,
  BEAM-internal module identity, baseline, and structural classification
  before a caller may turn any module name into an atom.
  """

  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.WAL

  @schema "openagents.forge.build-artifact.v1"
  @max_artifact_bytes 32 * 1_048_576
  @max_manifest_bytes 1_048_576
  @max_beam_bytes 4 * 1_048_576
  @max_modules 512
  @manifest_keys ~w(schema build_id repo source_sha baseline toolchain classification structural_reasons changes modules)
  @toolchain_keys ~w(elixir otp erts application_version application_spec_sha256 mix_lock_sha256)
  @change_keys ~w(added changed deleted)
  @module_keys ~w(name sha256 size)
  @classification ~w(direct_candidate needs_rolling_replace)
  @module_pattern ~r/^Elixir\.OpenAgents(?:\.[A-Za-z][A-Za-z0-9_]*)+$/

  @type beam :: %{module: String.t(), binary: binary()}
  @type verified :: %{
          digest: String.t(),
          manifest: map(),
          beams: [beam()],
          modules: [String.t()]
        }

  @doc "Normalize BEAM bytes by retaining only OTP-defined significant chunks."
  @spec normalize_beam(binary()) :: {:ok, binary()} | {:error, term()}
  def normalize_beam(binary) when is_binary(binary) and byte_size(binary) <= @max_beam_bytes do
    case :beam_lib.strip(binary) do
      {:ok, {_module, normalized}} when byte_size(normalized) <= @max_beam_bytes ->
        {:ok, normalized}

      {:ok, {_module, _too_large}} ->
        {:error, :beam_too_large}

      {:error, _module, reason} ->
        {:error, {:invalid_beam, reason}}
    end
  rescue
    _error -> {:error, :invalid_beam}
  end

  def normalize_beam(_binary), do: {:error, :beam_too_large}

  @doc "Current compiler/runtime identity recorded in every build manifest."
  @spec current_toolchain(keyword()) :: map()
  def current_toolchain(opts \\ []) do
    lock_path = Keyword.get(opts, :lock_path, "mix.lock")
    app_file = Keyword.get(opts, :app_file)

    %{
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "erts" => to_string(:erlang.system_info(:version)),
      "application_version" => application_version(app_file),
      "application_spec_sha256" => application_spec_digest(app_file),
      "mix_lock_sha256" => file_digest(lock_path)
    }
  end

  @doc "Create a deterministic verified artifact from the full candidate module set."
  @spec pack(String.t(), String.t(), String.t(), [beam()], keyword()) ::
          {:ok, %{bytes: binary(), digest: String.t(), manifest: map(), beams: [beam()]}}
          | {:error, term()}
  def pack(repo, source_sha, build_id, candidate_beams, opts \\ []) do
    baseline = Keyword.get(opts, :baseline_manifest)
    toolchain = Keyword.get(opts, :toolchain, current_toolchain())
    structural_reasons = Keyword.get(opts, :structural_reasons, [])

    with :ok <- WAL.validate_repo(repo),
         :ok <- validate_sha(source_sha),
         :ok <- validate_uuid(build_id),
         {:ok, normalized} <- normalize_candidates(candidate_beams),
         {:ok, baseline_modules} <- baseline_modules(baseline),
         {:ok, toolchain} <- validate_toolchain(toolchain),
         {:ok, manifest, changed_beams} <-
           build_manifest(
             repo,
             source_sha,
             build_id,
             normalized,
             baseline,
             baseline_modules,
             toolchain,
             structural_reasons
           ),
         {:ok, bytes} <- create_tar(manifest, changed_beams),
         digest = digest(bytes),
         {:ok, verified} <-
           verify(bytes,
             digest: digest,
             repo: repo,
             source_sha: source_sha,
             build_id: build_id
           ) do
      {:ok,
       %{
         bytes: bytes,
         digest: digest,
         manifest: manifest,
         beams: verified.beams
       }}
    end
  end

  @doc "Verify an artifact without creating atoms."
  @spec verify(binary(), keyword()) :: {:ok, verified()} | {:error, term()}
  def verify(bytes, opts \\ [])

  def verify(bytes, opts) when is_binary(bytes) do
    expected_digest = Keyword.get(opts, :digest)

    with :ok <- validate_artifact_size(bytes),
         actual_digest = digest(bytes),
         :ok <- match_expected(actual_digest, expected_digest, :artifact_digest_mismatch),
         {:ok, entries} <- extract_entries(bytes),
         {:ok, manifest_bytes, beam_entries} <- split_entries(entries),
         {:ok, manifest} <- decode_manifest(manifest_bytes),
         :ok <- validate_manifest(manifest),
         :ok <- validate_expected_identity(manifest, opts),
         {:ok, beams} <- verify_beams(beam_entries, manifest),
         :ok <- verify_change_entries(beams, manifest) do
      {:ok,
       %{
         digest: actual_digest,
         manifest: manifest,
         beams: beams,
         modules: Enum.map(beams, & &1.module)
       }}
    end
  end

  def verify(_bytes, _opts), do: {:error, :invalid_artifact}

  @doc "Read and verify a local artifact."
  @spec verify_file(Path.t(), keyword()) :: {:ok, verified()} | {:error, term()}
  def verify_file(path, opts \\ []) do
    with {:ok, bytes} <- File.read(path), do: verify(bytes, opts)
  end

  @doc "Return the module identity embedded in a BEAM without creating an atom."
  @spec beam_module(binary()) :: {:ok, String.t()} | {:error, term()}
  def beam_module(binary) when is_binary(binary) do
    with {:ok, beam} <- maybe_gunzip(binary),
         {:ok, chunks} <- beam_chunks(beam),
         {:ok, atom_chunk, encoding} <- atom_chunk(chunks),
         {:ok, module} <- first_atom(atom_chunk, encoding),
         true <- valid_module?(module) or {:error, :invalid_module_name} do
      {:ok, module}
    else
      false -> {:error, :invalid_beam_identity}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :invalid_beam_identity}
  end

  @doc "Create a module atom only after `verify/2` has accepted the full artifact."
  @spec module_atom(String.t()) :: atom()
  def module_atom(module) when is_binary(module) do
    if valid_module?(module),
      do: String.to_atom(module),
      else: raise(ArgumentError, "invalid verified module name")
  end

  @doc "SHA-256 digest as lowercase hexadecimal."
  def digest(bytes) when is_binary(bytes) do
    :sha256
    |> :crypto.hash(bytes)
    |> Base.encode16(case: :lower)
  end

  defp normalize_candidates(beams) when is_list(beams) and length(beams) <= @max_modules do
    beams
    |> Enum.reduce_while({:ok, %{}}, fn
      %{module: module, binary: binary}, {:ok, acc}
      when is_binary(module) and is_binary(binary) ->
        with true <- valid_module?(module) or {:error, :invalid_module_name},
             true <- not Map.has_key?(acc, module) or {:error, :duplicate_module},
             {:ok, normalized} <- normalize_beam(binary),
             {:ok, ^module} <- beam_module(normalized) do
          {:cont, {:ok, Map.put(acc, module, normalized)}}
        else
          {:error, _reason} = error -> {:halt, error}
          _other -> {:halt, {:error, :beam_module_mismatch}}
        end

      _beam, _acc ->
        {:halt, {:error, :invalid_beam_entry}}
    end)
  end

  defp normalize_candidates(_beams), do: {:error, :too_many_modules}

  defp build_manifest(
         repo,
         source_sha,
         build_id,
         normalized,
         baseline,
         baseline_modules,
         toolchain,
         structural_reasons
       ) do
    current_modules = Map.new(normalized, fn {module, binary} -> {module, digest(binary)} end)
    added = current_modules |> Map.keys() |> Enum.reject(&Map.has_key?(baseline_modules, &1))

    changed =
      current_modules
      |> Enum.filter(fn {module, module_digest} ->
        match?(
          %{^module => baseline_digest} when baseline_digest != module_digest,
          baseline_modules
        )
      end)
      |> Enum.map(&elem(&1, 0))

    deleted = baseline_modules |> Map.keys() |> Enum.reject(&Map.has_key?(current_modules, &1))

    toolchain_reasons = toolchain_reasons(baseline, toolchain)

    reasons =
      structural_reasons
      |> Enum.map(&to_string/1)
      |> Kernel.++(if(deleted == [], do: [], else: ["module_deletion"]))
      |> Kernel.++(toolchain_reasons)
      |> Enum.uniq()
      |> Enum.sort()

    classification = if reasons == [], do: "direct_candidate", else: "needs_rolling_replace"

    module_entries =
      normalized
      |> Enum.map(fn {module, binary} ->
        %{"name" => module, "sha256" => digest(binary), "size" => byte_size(binary)}
      end)
      |> Enum.sort_by(& &1["name"])

    manifest = %{
      "schema" => @schema,
      "build_id" => build_id,
      "repo" => repo,
      "source_sha" => source_sha,
      "baseline" => baseline_identity(baseline),
      "toolchain" => toolchain,
      "classification" => classification,
      "structural_reasons" => reasons,
      "changes" => %{
        "added" => Enum.sort(added),
        "changed" => Enum.sort(changed),
        "deleted" => Enum.sort(deleted)
      },
      "modules" => module_entries
    }

    changed_names = MapSet.new(added ++ changed)

    changed_beams =
      normalized
      |> Enum.filter(fn {module, _binary} -> MapSet.member?(changed_names, module) end)
      |> Enum.map(fn {module, binary} -> %{module: module, binary: binary} end)
      |> Enum.sort_by(& &1.module)

    {:ok, manifest, changed_beams}
  end

  defp create_tar(manifest, beams) do
    manifest_json = BuildProtocol.canonical_json(manifest)

    entries =
      [{~c"manifest.json", manifest_json}] ++
        Enum.map(beams, fn %{module: module, binary: binary} ->
          {String.to_charlist("beams/" <> module <> ".beam"), binary}
        end)

    path =
      Path.join(
        System.tmp_dir!(),
        "openagents-artifact-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    try do
      with :ok <- :erl_tar.create(String.to_charlist(path), entries),
           {:ok, bytes} <- File.read(path),
           :ok <- validate_artifact_size(bytes) do
        {:ok, bytes}
      end
    after
      File.rm(path)
    end
  end

  defp extract_entries(bytes) do
    case :erl_tar.extract({:binary, bytes}, [:memory]) do
      {:ok, entries} when length(entries) <= @max_modules + 1 ->
        normalized = Enum.map(entries, fn {name, value} -> {to_string(name), value} end)

        if Enum.uniq_by(normalized, &elem(&1, 0)) == normalized,
          do: {:ok, normalized},
          else: {:error, :duplicate_artifact_entry}

      {:ok, _entries} ->
        {:error, :too_many_artifact_entries}

      {:error, reason} ->
        {:error, {:invalid_tar, reason}}
    end
  rescue
    _error -> {:error, :invalid_tar}
  end

  defp split_entries(entries) do
    case Enum.split_with(entries, fn {name, _value} -> name == "manifest.json" end) do
      {[{"manifest.json", manifest}], beam_entries}
      when byte_size(manifest) <= @max_manifest_bytes ->
        if Enum.all?(beam_entries, fn {name, binary} ->
             valid_beam_path?(name) and is_binary(binary) and byte_size(binary) <= @max_beam_bytes
           end) do
          {:ok, manifest, beam_entries}
        else
          {:error, :invalid_artifact_entry}
        end

      {[_manifest], _beam_entries} ->
        {:error, :manifest_too_large}

      _other ->
        {:error, :manifest_count}
    end
  end

  defp decode_manifest(bytes) do
    with {:ok, manifest} <- Jason.decode(bytes),
         true <-
           BuildProtocol.canonical_json(manifest) == bytes or {:error, :noncanonical_manifest} do
      {:ok, manifest}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_manifest_json}
    end
  end

  defp validate_manifest(%{} = manifest) do
    with :ok <- exact_keys(manifest, @manifest_keys),
         true <- manifest["schema"] == @schema or {:error, :invalid_manifest_schema},
         :ok <- validate_uuid(manifest["build_id"]),
         :ok <- WAL.validate_repo(manifest["repo"]),
         :ok <- validate_sha(manifest["source_sha"]),
         :ok <- validate_baseline_identity(manifest["baseline"]),
         {:ok, _toolchain} <- validate_toolchain(manifest["toolchain"]),
         true <-
           manifest["classification"] in @classification or
             {:error, :invalid_classification},
         :ok <- validate_reasons(manifest["structural_reasons"]),
         :ok <- validate_changes(manifest["changes"]),
         :ok <- validate_modules(manifest["modules"]),
         :ok <- validate_classification(manifest) do
      :ok
    else
      false -> {:error, :invalid_manifest}
      {:error, _reason} = error -> error
    end
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_manifest}

  defp verify_beams(entries, manifest) do
    metadata = Map.new(manifest["modules"], &{&1["name"], &1})

    entries
    |> Enum.reduce_while({:ok, []}, fn {path, binary}, {:ok, acc} ->
      module = path |> String.replace_prefix("beams/", "") |> String.replace_suffix(".beam", "")

      with %{} = declared <- metadata[module] || {:error, :undeclared_module},
           true <- declared["size"] == byte_size(binary) or {:error, :beam_size_mismatch},
           true <- declared["sha256"] == digest(binary) or {:error, :beam_digest_mismatch},
           {:ok, embedded} <- beam_module(binary),
           true <- embedded == module or {:error, :beam_module_mismatch} do
        {:cont, {:ok, [%{module: module, binary: binary} | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
        _other -> {:halt, {:error, :invalid_beam_entry}}
      end
    end)
    |> case do
      {:ok, beams} -> {:ok, Enum.sort_by(beams, & &1.module)}
      error -> error
    end
  end

  defp verify_change_entries(beams, manifest) do
    expected = Enum.sort(manifest["changes"]["added"] ++ manifest["changes"]["changed"])
    actual = Enum.map(beams, & &1.module)
    if actual == expected, do: :ok, else: {:error, :artifact_change_set_mismatch}
  end

  defp validate_expected_identity(manifest, opts) do
    checks = [
      {"repo", Keyword.get(opts, :repo)},
      {"source_sha", Keyword.get(opts, :source_sha)},
      {"build_id", Keyword.get(opts, :build_id)}
    ]

    Enum.reduce_while(checks, :ok, fn
      {_field, nil}, :ok ->
        {:cont, :ok}

      {field, expected}, :ok ->
        if manifest[field] == expected,
          do: {:cont, :ok},
          else: {:halt, {:error, {:manifest_identity_mismatch, field}}}
    end)
  end

  defp baseline_modules(nil), do: {:ok, %{}}

  defp baseline_modules(%{} = manifest) do
    with :ok <- validate_manifest(manifest) do
      {:ok, Map.new(manifest["modules"], &{&1["name"], &1["sha256"]})}
    end
  end

  defp baseline_modules(_manifest), do: {:error, :invalid_baseline_manifest}

  defp baseline_identity(nil), do: nil

  defp baseline_identity(manifest) do
    %{
      "build_id" => manifest["build_id"],
      "source_sha" => manifest["source_sha"],
      "manifest_sha256" => digest(BuildProtocol.canonical_json(manifest))
    }
  end

  defp validate_baseline_identity(nil), do: :ok

  defp validate_baseline_identity(%{} = identity) do
    with :ok <- exact_keys(identity, ~w(build_id source_sha manifest_sha256)),
         :ok <- validate_uuid(identity["build_id"]),
         :ok <- validate_sha(identity["source_sha"]),
         :ok <- validate_digest(identity["manifest_sha256"]) do
      :ok
    end
  end

  defp validate_baseline_identity(_identity), do: {:error, :invalid_baseline_identity}

  defp toolchain_reasons(nil, _toolchain), do: ["baseline_missing"]

  defp toolchain_reasons(%{"toolchain" => baseline}, toolchain) do
    @toolchain_keys
    |> Enum.reject(fn key -> baseline[key] == toolchain[key] end)
    |> Enum.map(&"toolchain_#{&1}_changed")
  end

  defp toolchain_reasons(_baseline, _toolchain), do: ["baseline_invalid"]

  defp validate_toolchain(%{} = toolchain) do
    with :ok <- exact_keys(toolchain, @toolchain_keys),
         true <-
           Enum.all?(@toolchain_keys, &valid_identity_value?(toolchain[&1])) or
             {:error, :invalid_toolchain} do
      {:ok, toolchain}
    end
  end

  defp validate_toolchain(_toolchain), do: {:error, :invalid_toolchain}

  defp valid_identity_value?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp validate_changes(%{} = changes) do
    with :ok <- exact_keys(changes, @change_keys),
         true <-
           Enum.all?(@change_keys, &valid_module_list?(changes[&1])) or
             {:error, :invalid_changes},
         all = Enum.flat_map(@change_keys, &changes[&1]),
         true <- length(all) == length(Enum.uniq(all)) or {:error, :overlapping_changes} do
      :ok
    end
  end

  defp validate_changes(_changes), do: {:error, :invalid_changes}

  defp validate_modules(modules) when is_list(modules) and length(modules) <= @max_modules do
    result =
      Enum.reduce_while(modules, {:ok, []}, fn
        %{} = module, {:ok, names} ->
          with :ok <- exact_keys(module, @module_keys),
               true <- valid_module?(module["name"]) or {:error, :invalid_module_name},
               :ok <- validate_digest(module["sha256"]),
               true <-
                 (is_integer(module["size"]) and module["size"] in 1..@max_beam_bytes) or
                   {:error, :invalid_module_size} do
            {:cont, {:ok, [module["name"] | names]}}
          else
            {:error, _reason} = error -> {:halt, error}
          end

        _module, _acc ->
          {:halt, {:error, :invalid_module_metadata}}
      end)

    case result do
      {:ok, names} ->
        sorted = Enum.sort(names)

        cond do
          names != Enum.reverse(sorted) ->
            # The reduce accumulates in reverse, so canonical source order is
            # the reverse of the accumulated list.
            {:error, :unsorted_modules}

          length(names) != length(Enum.uniq(names)) ->
            {:error, :duplicate_module}

          true ->
            :ok
        end

      error ->
        error
    end
  end

  defp validate_modules(_modules), do: {:error, :too_many_modules}

  defp validate_reasons(reasons) when is_list(reasons) and length(reasons) <= 64 do
    if Enum.all?(reasons, fn reason ->
         is_binary(reason) and byte_size(reason) in 1..128 and
           Regex.match?(~r/^[a-z0-9_]+$/, reason)
       end) and reasons == Enum.sort(Enum.uniq(reasons)) do
      :ok
    else
      {:error, :invalid_structural_reasons}
    end
  end

  defp validate_reasons(_reasons), do: {:error, :invalid_structural_reasons}

  defp validate_classification(manifest) do
    expected =
      if manifest["structural_reasons"] == [],
        do: "direct_candidate",
        else: "needs_rolling_replace"

    if manifest["classification"] == expected,
      do: :ok,
      else: {:error, :classification_mismatch}
  end

  defp valid_module_list?(list) when is_list(list) and length(list) <= @max_modules do
    Enum.all?(list, &valid_module?/1) and list == Enum.sort(Enum.uniq(list))
  end

  defp valid_module_list?(_list), do: false

  defp valid_module?(module) when is_binary(module) and byte_size(module) <= 255,
    do: Regex.match?(@module_pattern, module)

  defp valid_module?(_module), do: false

  defp valid_beam_path?("beams/" <> rest = path) do
    module = String.replace_suffix(rest, ".beam", "")

    String.ends_with?(rest, ".beam") and path == "beams/" <> module <> ".beam" and
      valid_module?(module)
  end

  defp valid_beam_path?(_path), do: false

  defp validate_artifact_size(bytes) when byte_size(bytes) in 1..@max_artifact_bytes, do: :ok
  defp validate_artifact_size(_bytes), do: {:error, :artifact_too_large}

  defp validate_sha(value) when is_binary(value) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, value), do: :ok, else: {:error, :invalid_source_sha}
  end

  defp validate_sha(_value), do: {:error, :invalid_source_sha}

  defp validate_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_build_id}
    end
  end

  defp validate_uuid(_value), do: {:error, :invalid_build_id}

  defp validate_digest(value) when is_binary(value) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, value), do: :ok, else: {:error, :invalid_digest}
  end

  defp validate_digest(_value), do: {:error, :invalid_digest}

  defp match_expected(_actual, nil, _reason), do: :ok
  defp match_expected(actual, actual, _reason), do: :ok
  defp match_expected(_actual, _expected, reason), do: {:error, reason}

  defp exact_keys(map, allowed) do
    if Map.keys(map) |> Enum.sort() == Enum.sort(allowed),
      do: :ok,
      else: {:error, :unexpected_manifest_fields}
  end

  defp maybe_gunzip(<<31, 139, _rest::binary>> = binary) do
    uncompressed = :zlib.gunzip(binary)

    if byte_size(uncompressed) <= @max_beam_bytes * 2,
      do: {:ok, uncompressed},
      else: {:error, :beam_uncompressed_too_large}
  rescue
    _error -> {:error, :invalid_gzip_beam}
  end

  defp maybe_gunzip(binary), do: {:ok, binary}

  defp beam_chunks(<<"FOR1", declared::32-big, "BEAM", rest::binary>>)
       when declared == byte_size(rest) + 4 do
    parse_chunks(rest, %{})
  end

  defp beam_chunks(_binary), do: {:error, :invalid_beam_container}

  defp parse_chunks(<<>>, chunks), do: {:ok, chunks}

  defp parse_chunks(<<id::binary-size(4), size::32-big, rest::binary>>, chunks)
       when size <= @max_beam_bytes do
    if Map.has_key?(chunks, id) do
      {:error, :duplicate_beam_chunk}
    else
      padded = size + rem(4 - rem(size, 4), 4)
      padding_size = padded - size

      if byte_size(rest) >= padded do
        <<chunk::binary-size(^size), _padding::binary-size(^padding_size), tail::binary>> = rest
        parse_chunks(tail, Map.put(chunks, id, chunk))
      else
        {:error, :truncated_beam_chunk}
      end
    end
  end

  defp parse_chunks(_rest, _chunks), do: {:error, :invalid_beam_chunk}

  defp atom_chunk(%{"AtU8" => chunk}), do: {:ok, chunk, :utf8}
  defp atom_chunk(%{"Atom" => chunk}), do: {:ok, chunk, :latin1}
  defp atom_chunk(_chunks), do: {:error, :missing_atom_chunk}

  defp first_atom(<<count::32-signed-big, rest::binary>>, :utf8) when count < 0 do
    with {:ok, length, atoms} <- compact_length(rest),
         true <- length in 1..255 or {:error, :invalid_atom_length},
         <<name::binary-size(^length), _tail::binary>> <- atoms,
         true <- String.valid?(name) or {:error, :invalid_utf8_atom} do
      {:ok, name}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :truncated_atom_chunk}
    end
  end

  defp first_atom(<<count::32-signed-big, length, rest::binary>>, encoding) when count > 0 do
    with true <- length in 1..255 or {:error, :invalid_atom_length},
         <<name::binary-size(^length), _tail::binary>> <- rest do
      case encoding do
        :utf8 -> if String.valid?(name), do: {:ok, name}, else: {:error, :invalid_utf8_atom}
        :latin1 -> {:ok, :unicode.characters_to_binary(name, :latin1, :utf8)}
      end
    else
      {:error, _reason} = error -> error
      _other -> {:error, :truncated_atom_chunk}
    end
  end

  defp first_atom(_chunk, _encoding), do: {:error, :empty_atom_table}

  # OTP 28 long atom-table length encoding. Atom lengths need only the two
  # compact unsigned forms (0..2047), matching beam_lib's own bounded decoder.
  defp compact_length(<<high::4, 0::1, _tag::3, rest::binary>>), do: {:ok, high, rest}

  defp compact_length(<<high::3, 0::1, 1::1, _tag::3, low, rest::binary>>),
    do: {:ok, Bitwise.bor(Bitwise.bsl(high, 8), low), rest}

  defp compact_length(_binary), do: {:error, :invalid_atom_length_encoding}

  defp application_version(nil) do
    case Application.spec(:openagents, :vsn) do
      nil -> "unknown"
      value -> to_string(value)
    end
  end

  defp application_version(app_file) do
    with {:ok, contents} <- File.read(app_file),
         [version] <- Regex.run(~r/\{vsn,"([^"]{1,128})"\}/, contents, capture: :all_but_first) do
      version
    else
      _missing_or_invalid -> "unknown"
    end
  end

  defp application_spec_digest(nil) do
    case :code.where_is_file(~c"openagents.app") do
      :non_existing -> digest("missing")
      path -> file_digest(to_string(path))
    end
  end

  defp application_spec_digest(path), do: file_digest(path)

  defp file_digest(path) do
    case File.read(path) do
      {:ok, bytes} -> digest(bytes)
      {:error, _reason} -> digest("missing:" <> to_string(path))
    end
  end
end
