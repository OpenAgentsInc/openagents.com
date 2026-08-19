defmodule OpenAgents.Persona do
  @moduledoc """
  Loads and installs the immutable Sarah persona artifact for this release.

  The artifact contains both the first-conversation greeting and the protected
  core persona instructions. Its digest is admitted in code so changing the
  contents requires a new reviewed artifact version.
  """

  @enforce_keys [
    :id,
    :version,
    :content,
    :digest,
    :greeting,
    :source_manifest_id,
    :source_manifest_digest
  ]
  defstruct @enforce_keys

  @artifact_id "sarah.persona.v1"
  @artifact_version 1
  @artifact_path "sarah/persona/sarah.v1.md"
  @admitted_digest "9c738125c5f4799d2bc7c88f0eb22ce8f979289991612976172ab732e6471227"
  @persistent_key {__MODULE__, :current}

  alias OpenAgents.Persona.SourceManifest

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          content: String.t(),
          digest: String.t(),
          greeting: String.t(),
          source_manifest_id: String.t(),
          source_manifest_digest: String.t()
        }

  @type reason :: atom() | tuple()

  @spec install!(map()) :: t()
  def install!(source_manifest) do
    persona = load!(source_manifest)
    :persistent_term.put(@persistent_key, persona)
    persona
  end

  @spec current!() :: t()
  def current! do
    case :persistent_term.get(@persistent_key, :not_installed) do
      :not_installed -> raise "Sarah persona is not installed"
      %__MODULE__{} = persona -> persona
    end
  end

  @spec greeting() :: String.t()
  def greeting, do: current!().greeting

  @spec load!(map()) :: t()
  def load!(source_manifest) do
    case load(source_manifest) do
      {:ok, persona} ->
        persona

      {:error, reason} ->
        raise ArgumentError, "invalid Sarah persona artifact: #{inspect(reason)}"
    end
  end

  @spec load(map()) :: {:ok, t()} | {:error, reason()}
  def load(source_manifest) do
    with :ok <- validate_source_manifest(source_manifest),
         {:ok, path} <- artifact_path(),
         {:ok, contents} <- read(path),
         {:ok, persona} <- from_content(source_manifest, contents) do
      {:ok, persona}
    end
  end

  @doc false
  @spec from_content(map(), String.t()) :: {:ok, t()} | {:error, reason()}
  def from_content(source_manifest, contents)
      when is_map(source_manifest) and is_binary(contents) do
    with :ok <- validate_source_manifest(source_manifest),
         {:ok, greeting} <- extract(contents, "greeting"),
         {:ok, instructions} <- extract(contents, "instructions"),
         :ok <- validate_greeting(greeting),
         :ok <- validate_instructions(instructions),
         digest <- digest(contents),
         :ok <- validate_digest(digest) do
      {:ok,
       %__MODULE__{
         id: @artifact_id,
         version: @artifact_version,
         content: instructions,
         digest: digest,
         greeting: greeting,
         source_manifest_id: source_manifest["id"],
         source_manifest_digest: source_manifest["manifest_sha256"]
       }}
    end
  end

  def from_content(_source_manifest, _contents), do: {:error, :invalid_artifact_input}

  @spec digest(String.t()) :: String.t()
  def digest(contents) when is_binary(contents) do
    contents
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp artifact_path do
    case :code.priv_dir(:sarah) do
      path when is_list(path) -> {:ok, Path.join(List.to_string(path), @artifact_path)}
      {:error, reason} -> {:error, {:priv_dir_unavailable, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:artifact_read_failed, reason}}
    end
  end

  defp validate_source_manifest(
         %{
           "id" => "sarah.persona.sources.v1",
           "persona_id" => @artifact_id,
           "manifest_sha256" => digest
         } = source_manifest
       )
       when is_binary(digest) do
    case SourceManifest.validate(source_manifest) do
      {:ok, _validated_manifest} -> :ok
      {:error, reason} -> {:error, {:invalid_source_manifest, reason}}
    end
  end

  defp validate_source_manifest(_source_manifest), do: {:error, :source_manifest_mismatch}

  defp extract(contents, section) do
    start_marker = "<!-- #{section}:start -->"
    end_marker = "<!-- #{section}:end -->"

    with [_, after_start] <- String.split(contents, start_marker, parts: 2),
         [value, _after_end] <- String.split(after_start, end_marker, parts: 2),
         value <- String.trim(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> {:error, {:missing_artifact_section, section}}
    end
  end

  defp validate_greeting("Hello. I'm Sarah—an OpenAgent. What are we working on?"), do: :ok
  defp validate_greeting(_greeting), do: {:error, :unadmitted_greeting}

  defp validate_instructions(instructions) do
    normalized_instructions = String.replace(instructions, ~r/\s+/, " ")

    required_statements = [
      "You are OpenAgents.",
      "You are an OpenAgent",
      "You are an AI",
      "Current evidence outranks remembered evidence.",
      "Do not use military framing in ordinary conversation."
    ]

    case Enum.find(required_statements, &(not String.contains?(normalized_instructions, &1))) do
      nil -> :ok
      statement -> {:error, {:missing_required_instruction, statement}}
    end
  end

  defp validate_digest(@admitted_digest), do: :ok
  defp validate_digest(_digest), do: {:error, :persona_digest_not_admitted}
end
