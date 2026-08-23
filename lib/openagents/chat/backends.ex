defmodule OpenAgents.Chat.Backends do
  @moduledoc """
  The one place that names the inference backends a chat turn may choose.

  A backend is a model and the adapter that reaches it, named by a stable id a
  client sends and a label a person reads. Everything that needs to know the
  set reads it from here: the turn runtime picks the adapter, the chat API
  refuses an id that is not in the list, and `GET /api/v3` publishes the ids so
  a client discovers the choice instead of hardcoding it. Adding a backend is
  one entry in `@backends`, and every one of those surfaces follows.

  That single list is the point. The alternative — a string in the controller,
  another in the runtime, a third in the published document — is how a client
  comes to be offered a backend the server will refuse, which is exactly the
  drift the API-001 governance test exists to catch.

  Every backend answers with the same events and the same completion shape, so
  the choice changes which model replies and nothing else about how a turn is
  read.
  """

  alias OpenAgents.Chat.{Gemini, OpenRouter}

  @backends [
    %{
      id: "ox-alpha",
      label: "Ox Alpha",
      adapter: OpenRouter,
      model: nil,
      description: "Ox Alpha through OpenRouter. The default when a turn names no backend.",
      free: false
    },
    %{
      id: "gemini-3.7-flash",
      label: "Gemini 3.7 Flash",
      adapter: Gemini,
      model: "gemini-3.7-flash",
      description:
        "Gemini 3.7 Flash, served through this API on the OpenAgents Google balance, " <>
          "so a caller spends nothing and holds no key of their own.",
      free: true
    }
  ]

  @default_id "ox-alpha"

  @type t :: %{
          id: String.t(),
          label: String.t(),
          adapter: module(),
          model: String.t() | nil,
          description: String.t(),
          free: boolean()
        }

  @doc "Every supported backend, in the order a client should offer them."
  @spec all() :: [t()]
  def all, do: @backends

  @doc """
  The supported backend ids.

  `OpenAgentsWeb.ApiExtensionController` publishes this list as the enum for
  the `model` parameter, so the published contract is derived from the same
  value the runtime refuses against and the two cannot drift.
  """
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@backends, & &1.id)

  @doc "The backend a turn uses when it names none."
  @spec default() :: t()
  def default, do: fetch!(@default_id)

  @doc "The id of the default backend."
  @spec default_id() :: String.t()
  def default_id, do: @default_id

  @doc """
  The backend with this id.

  `nil` and an empty string mean "the caller expressed no preference" and
  resolve to the default. Any other unknown value is a refusal, not a silent
  fallback: a caller that asked for a specific model and got a different one
  would have no way to tell.
  """
  @spec fetch(term()) :: {:ok, t()} | {:error, :unsupported_backend}
  def fetch(id) when id in [nil, ""], do: {:ok, default()}

  def fetch(id) when is_binary(id) do
    case Enum.find(@backends, &(&1.id == id)) do
      nil -> {:error, :unsupported_backend}
      backend -> {:ok, backend}
    end
  end

  def fetch(_id), do: {:error, :unsupported_backend}

  @doc "The backend with this id, raising when there is none."
  @spec fetch!(String.t()) :: t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, backend} ->
        backend

      {:error, :unsupported_backend} ->
        raise ArgumentError, "#{inspect(id)} is not a chat backend"
    end
  end

  @doc "The model id this backend requests, asking its adapter when it names none."
  @spec model(t()) :: String.t()
  def model(%{model: model}) when is_binary(model), do: model
  def model(%{adapter: adapter}), do: adapter.default_model()

  @doc "The streaming function for this backend, in the shape the turn runtime calls."
  @spec streamer(t()) :: (map(), (tuple() -> any()), keyword() -> {:ok, map()} | {:error, term()})
  def streamer(%{adapter: adapter}), do: &adapter.stream/3

  @doc "The public projection of a backend, for a client choosing between them."
  @spec public(t()) :: map()
  def public(%{} = backend) do
    %{
      "id" => backend.id,
      "label" => backend.label,
      "model" => model(backend),
      "description" => backend.description,
      "free" => backend.free,
      "default" => backend.id == @default_id
    }
  end

  @doc "The public projection of every supported backend."
  @spec catalog() :: [map()]
  def catalog, do: Enum.map(@backends, &public/1)
end
