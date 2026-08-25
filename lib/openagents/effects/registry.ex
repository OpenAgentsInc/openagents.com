defmodule OpenAgents.Effects.Registry do
  @moduledoc """
  Which module runs which kind of effect.

  The map is configuration, not a scan: an effect kind with no handler is a
  refusal, never a silent no-op, because an outbox that quietly drops an effect
  it does not recognize is exactly the "best-effort" behaviour the outbox
  exists to replace.

  Kinds are bounded strings admitted here. Nothing turns a payload string into
  a module or an atom at runtime.
  """

  @default_handlers %{
    "work.launch_worker" => OpenAgents.Effects.Handlers.WorkLaunch,
    "email.delivery" => OpenAgents.Effects.Handlers.EmailDelivery
  }

  @doc "Every admitted effect kind and its handler."
  @spec handlers() :: %{String.t() => module()}
  def handlers do
    configured =
      :openagents
      |> Application.get_env(:effects, [])
      |> Keyword.get(:handlers, %{})
      |> Map.new()

    Map.merge(@default_handlers, configured)
  end

  @doc "Every effect kind this release can run."
  @spec kinds() :: [String.t()]
  def kinds, do: handlers() |> Map.keys() |> Enum.sort()

  @doc "Resolve one kind to its handler."
  @spec fetch(String.t()) :: {:ok, module()} | {:error, :unknown_kind}
  def fetch(kind) when is_binary(kind) do
    case Map.fetch(handlers(), kind) do
      {:ok, handler} -> {:ok, handler}
      :error -> {:error, :unknown_kind}
    end
  end
end
