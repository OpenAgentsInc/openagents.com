defmodule OpenAgents.Plugins.Index do
  @moduledoc """
  A typed index of validated plugin manifests.

  The index accepts a source of `{repository, release, raw_manifest}` entries
  and surfaces only those whose manifests validate. It supports listing and
  exact-name lookup, leaving semantic selection to callers.
  """

  require Logger

  alias OpenAgents.Plugins.Manifest

  defmodule Entry do
    @moduledoc "One indexed, validated plugin release."
    defstruct [:repository, :release, :manifest]

    @type t :: %__MODULE__{
            repository: String.t(),
            release: String.t(),
            manifest: map()
          }
  end

  @doc "List validated plugin entries from the configured or provided source."
  @spec list(keyword()) :: [Entry.t()]
  def list(opts \\ []) do
    source = Keyword.get(opts, :source, default_source())

    source
    |> fetch()
    |> Enum.reduce([], fn entry, acc ->
      case validate_entry(entry) do
        {:ok, validated} ->
          [validated | acc]

        {:error, %Manifest.ValidationError{} = error} ->
          Logger.warning(
            "plugin_manifest_invalid repository=#{entry.repository} release=#{entry.release} field=#{error.field}"
          )

          acc
      end
    end)
    |> Enum.reverse()
  end

  @doc "Look up one validated manifest by exact plugin name."
  @spec get(String.t(), keyword()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get(name, opts \\ []) when is_binary(name) do
    list(opts)
    |> Enum.find(fn %Entry{manifest: manifest} -> manifest["name"] == name end)
    |> case do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, :not_found}
    end
  end

  @doc "Render an index entry as a JSON-friendly map."
  @spec to_map(Entry.t()) :: map()
  def to_map(%Entry{repository: repository, release: release, manifest: manifest}) do
    %{
      "repository" => repository,
      "release" => release,
      "manifest" => manifest
    }
  end

  defp fetch(module) when is_atom(module), do: module.entries()

  defp fetch(entries) when is_list(entries) do
    entries
    |> Enum.map(&to_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp to_entry(%{repository: repository, release: release, raw_manifest: raw_manifest})
       when is_binary(repository) and is_binary(release) and is_map(raw_manifest) do
    %Entry{repository: repository, release: release, manifest: raw_manifest}
  end

  defp to_entry(%Entry{} = entry), do: entry

  defp to_entry(_invalid) do
    Logger.warning("plugin_index_malformed_entry")
    nil
  end

  defp validate_entry(%Entry{manifest: raw_manifest} = entry) do
    case Manifest.validate(raw_manifest) do
      {:ok, manifest} -> {:ok, %Entry{entry | manifest: manifest}}
      {:error, %Manifest.ValidationError{} = error} -> {:error, error}
    end
  end

  defp default_source do
    Application.get_env(:openagents, OpenAgents.Plugins.Index,
      source: OpenAgents.Plugins.ForgeSource
    )[
      :source
    ]
  end
end
