defmodule OpenAgents.Deployments.SecretResolver do
  @moduledoc """
  Resolves an environment's declared secret references into values, at execution
  time only.

  Durable records hold references. Values exist for the duration of one attempt,
  inside one `OpenAgents.Deployments.Execution`, and are handed only to the
  provider bound to that environment. Nothing writes a value to a run, an event,
  a receipt, or a log.

  A resolver may only resolve references the environment declares. That bound is
  what stops a provider or a tenant configuration change from reading a
  credential belonging to another environment.
  """

  alias OpenAgents.Deployments.Environment

  @callback resolve(Environment.t(), [String.t()]) ::
              {:ok, %{optional(String.t()) => String.t()}}
              | {:error, {:missing_secret_reference, String.t()}}

  @doc """
  Resolve the references the environment declares, refusing anything else.

  An undeclared reference is a programming error in a provider, so it is refused
  rather than resolved.
  """
  @spec resolve(Environment.t(), [String.t()]) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error,
             {:missing_secret_reference, String.t()} | {:undeclared_secret_reference, String.t()}}
  def resolve(%Environment{} = environment, references) when is_list(references) do
    declared = MapSet.new(environment.secret_references)

    case Enum.find(references, &(not MapSet.member?(declared, &1))) do
      nil -> impl().resolve(environment, references)
      reference -> {:error, {:undeclared_secret_reference, reference}}
    end
  end

  defp impl do
    Application.get_env(
      :openagents,
      :deployment_secret_resolver,
      OpenAgents.Deployments.SecretResolver.Environment
    )
  end
end
