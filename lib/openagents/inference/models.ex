defmodule OpenAgents.Inference.Models do
  @moduledoc """
  The models a grant may pin, and the provider that serves each.

  A grant carries one model and the proxy pins it, so the set of models a
  caller may be granted is the set the proxy can route. This module is that
  single list: `OpenAgents.Threads` admits a thread's model against it,
  `OpenAgents.Inference.mint/1` refuses a grant naming anything else, and
  `OpenAgentsWeb.InferenceProxyController` asks it which provider to call.

  Two names appear per model and they are not the same name. The `id` is what a
  client asks for and what the grant publishes — `ox-alpha`. The
  `provider_model` is what the provider is called with — `stealth/ox-alpha`.
  Keeping them apart is what lets the routed vendor string change without
  invalidating grants that already name the model.

  The provider module for each lane is read from configuration rather than
  compiled in, so `config/test.exs` substitutes `OpenAgents.Providers.Test` for
  both lanes and no test reaches a vendor.
  """

  @ox_alpha "ox-alpha"

  @type t :: %{id: String.t(), provider: module(), provider_model: String.t()}

  @doc "Every model a grant may pin, in the order a client should offer them."
  @spec all() :: [t()]
  def all do
    [default(), ox_alpha()]
    |> Enum.uniq_by(& &1.id)
  end

  @doc "The model ids a grant may pin."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(all(), & &1.id)

  @doc "The model a grant pins when its caller names none."
  @spec default() :: t()
  def default do
    model = Application.fetch_env!(:openagents, :openai_model)

    %{
      id: model,
      provider: Application.fetch_env!(:openagents, :provider),
      provider_model: model
    }
  end

  @doc "The id of the model a grant pins when its caller names none."
  @spec default_id() :: String.t()
  def default_id, do: default().id

  @doc """
  The model with this id, or `:error`.

  A thread opened before this list existed carries the vendor string
  `stealth/ox-alpha` in its `model` column, so that spelling resolves to the
  same model rather than leaving those threads unable to mint.
  """
  @spec fetch(String.t() | nil) :: {:ok, t()} | :error
  def fetch(id) when is_binary(id) do
    normalized = if id == ox_alpha().provider_model, do: @ox_alpha, else: id

    case Enum.find(all(), &(&1.id == normalized)) do
      nil -> :error
      model -> {:ok, model}
    end
  end

  def fetch(_id), do: :error

  defp ox_alpha do
    %{
      id: @ox_alpha,
      provider: Application.fetch_env!(:openagents, :openrouter_provider),
      provider_model: OpenAgents.Chat.OpenRouter.default_model()
    }
  end
end
