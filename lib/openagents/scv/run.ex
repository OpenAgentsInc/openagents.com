defmodule OpenAgents.SCV.Run do
  @moduledoc "Defines one bounded SCV execution request."

  alias OpenAgents.SCV.Driver
  alias OpenAgents.SCV.Environment
  alias OpenAgents.SCV.Runner.Local

  @derive {Inspect, except: [:objective, :driver_options]}
  @enforce_keys [
    :id,
    :repository,
    :objective,
    :driver_module,
    :environment,
    :runner_module,
    :runner_id,
    :permission_profile,
    :capabilities,
    :driver_options
  ]
  defstruct [
    :id,
    :repository,
    :repository_revision,
    :objective,
    :driver_module,
    :environment,
    :runner_module,
    :runner_id,
    :permission_profile,
    :capabilities,
    :driver_options
  ]

  @type permission_profile :: :read_only | :workspace_write
  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          repository: Path.t(),
          repository_revision: String.t() | nil,
          objective: String.t(),
          driver_module: module(),
          environment: Environment.t(),
          runner_module: module(),
          runner_id: String.t(),
          permission_profile: permission_profile(),
          capabilities: [atom()],
          driver_options: keyword()
        }

  @spec new(Path.t(), String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(repository, objective, options \\ [])

  def new(repository, objective, options) when is_list(options) do
    driver = Keyword.get(options, :driver, :opencode)
    environment = Keyword.get(options, :environment, :opencode_core)
    permission_profile = Keyword.get(options, :permission_profile, :read_only)
    runner = Keyword.get(options, :runner, Local)
    run_id = Keyword.get(options, :run_id, Ecto.UUID.generate())
    repository_revision = Keyword.get(options, :repository_revision)
    driver_options = Keyword.get(options, :driver_options, [])

    with {:ok, repository} <- validate_repository(repository),
         :ok <- validate_objective(objective),
         {:ok, driver_module} <- Driver.fetch(driver),
         {:ok, environment} <- Environment.fetch(environment),
         :ok <- validate_permission_profile(permission_profile),
         {:ok, runner_module, runner_id} <- validate_runner(runner),
         :ok <- validate_run_id(run_id),
         :ok <- validate_repository_revision(repository_revision),
         :ok <- validate_driver_options(driver_options),
         capabilities <- driver_module.required_capabilities(permission_profile),
         true <-
           Environment.supports?(environment, capabilities) or {:error, :capability_mismatch} do
      {:ok,
       %__MODULE__{
         id: run_id,
         repository: repository,
         repository_revision: repository_revision,
         objective: objective,
         driver_module: driver_module,
         environment: environment,
         runner_module: runner_module,
         runner_id: runner_id,
         permission_profile: permission_profile,
         capabilities: capabilities,
         driver_options: driver_options
       }}
    end
  end

  def new(_repository, _objective, _options), do: {:error, :options_invalid}

  defp validate_repository(repository) when is_binary(repository) do
    expanded = Path.expand(repository)

    cond do
      Path.type(repository) != :absolute -> {:error, :repository_not_absolute}
      not File.dir?(expanded) -> {:error, :repository_not_found}
      true -> {:ok, expanded}
    end
  end

  defp validate_repository(_repository), do: {:error, :repository_invalid}

  defp validate_objective(objective)
       when is_binary(objective) and byte_size(objective) in 1..32_768 do
    if String.trim(objective) == "", do: {:error, :objective_empty}, else: :ok
  end

  defp validate_objective(_objective), do: {:error, :objective_invalid}

  defp validate_permission_profile(profile) when profile in [:read_only, :workspace_write],
    do: :ok

  defp validate_permission_profile(_profile), do: {:error, :permission_profile_not_admitted}

  defp validate_runner(Local), do: {:ok, Local, Local.id()}
  defp validate_runner(:local), do: {:ok, Local, Local.id()}
  defp validate_runner("local"), do: {:ok, Local, Local.id()}
  defp validate_runner(_runner), do: {:error, :runner_not_admitted}

  defp validate_run_id(run_id) when is_binary(run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, ^run_id} -> :ok
      _invalid -> {:error, :run_id_invalid}
    end
  end

  defp validate_run_id(_run_id), do: {:error, :run_id_invalid}

  defp validate_repository_revision(nil), do: :ok

  defp validate_repository_revision(revision) when is_binary(revision) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
      do: :ok,
      else: {:error, :repository_revision_invalid}
  end

  defp validate_repository_revision(_revision), do: {:error, :repository_revision_invalid}

  defp validate_driver_options(options) when is_list(options) do
    if Keyword.keyword?(options), do: :ok, else: {:error, :driver_options_invalid}
  end

  defp validate_driver_options(_options), do: {:error, :driver_options_invalid}
end
