defmodule OpenAgents.Memory.OpenAIEmbeddings do
  @moduledoc "Runtime-only OpenAI embeddings adapter; source text is never logged or persisted here."
  @behaviour OpenAgents.Memory.EmbeddingProvider

  @impl true
  def embed(text, config) do
    with {:ok, api_key} <- OpenAgents.RuntimeConfig.fetch_secret(:openai_api_key),
         {:ok, response} <-
           Req.post("https://api.openai.com/v1/embeddings",
             auth: {:bearer, api_key},
             receive_timeout: 15_000,
             json: %{
               "model" => config.model_id,
               "input" => text,
               "dimensions" => config.dimensions,
               "encoding_format" => "float"
             }
           ),
         200 <- response.status,
         [first | _rest] <- response.body["data"],
         embedding when is_list(embedding) <- first["embedding"] do
      {:ok, embedding}
    else
      {:error, :not_configured} -> {:error, :embedding_provider_unconfigured}
      _failure -> {:error, :embedding_provider_failed}
    end
  end
end
