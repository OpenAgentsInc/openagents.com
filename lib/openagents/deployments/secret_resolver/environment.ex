defmodule OpenAgents.Deployments.SecretResolver.Environment do
  @moduledoc """
  Resolves deployment secrets from the host process environment.

  The variable name is derived from the repository, the environment, and the
  reference, so one environment's binding cannot read another's value even when
  both declare the same reference name:

      OPENAGENTS_DEPLOY__<REPOSITORY>__<ENVIRONMENT>__<REFERENCE>

  This resolver exists because the first delivery phase runs against a fake
  provider, and a fake provider still has to prove the secret boundary. A hosted
  resolver replaces this module without changing any caller.
  """

  @behaviour OpenAgents.Deployments.SecretResolver

  alias OpenAgents.Deployments.Environment

  @impl true
  def resolve(%Environment{} = environment, references) do
    Enum.reduce_while(references, {:ok, %{}}, fn reference, {:ok, resolved} ->
      case System.get_env(variable_name(environment, reference)) do
        nil -> {:halt, {:error, {:missing_secret_reference, reference}}}
        value -> {:cont, {:ok, Map.put(resolved, reference, value)}}
      end
    end)
  end

  @doc "The host variable one environment's reference resolves from."
  @spec variable_name(Environment.t(), String.t()) :: String.t()
  def variable_name(%Environment{} = environment, reference) when is_binary(reference) do
    repository = environment.repository_id |> to_string() |> String.replace("-", "")

    "OPENAGENTS_DEPLOY__#{String.upcase(repository)}__#{upcase_segment(environment.name)}__#{reference}"
  end

  defp upcase_segment(value), do: value |> String.replace("-", "_") |> String.upcase()
end
