defmodule OpenAgents.Traces do
  @moduledoc """
  Store and retrieve account-scoped ATIF trace documents.
  """

  alias OpenAgents.Accounts.User
  alias OpenAgents.Repo
  alias OpenAgents.Traces.Trace

  @maximum_trace_bytes 10_485_760
  @atif_prefixes ["ATIF/1.", "ATIF-v1."]
  @default_visibility "dark"

  @doc "The largest trace body this surface accepts, in bytes."
  def maximum_trace_bytes, do: @maximum_trace_bytes

  @doc """
  Store an ATIF document for an account.

  Re-uploading the same canonical bytes for the same account returns the
  existing trace. A document without an admitted `schema_version` or one that
  exceeds the size ceiling is refused.
  """
  def store(%User{} = user, %{} = document), do: store(user, document, [])

  def store(%User{id: user_id} = _user, %{} = document, options) do
    canonical = Jason.encode!(document)
    byte_size = byte_size(canonical)

    cond do
      byte_size > @maximum_trace_bytes ->
        {:error, :body_too_large}

      not valid_atif?(document) ->
        {:error, :invalid_atif}

      true ->
        digest =
          "sha256:" <>
            (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))

        visibility = normalize_visibility(options, document)

        case Repo.get_by(Trace, user_id: user_id, digest: digest) do
          %Trace{} = existing ->
            {:ok, existing, :existing}

          nil ->
            attrs = %{
              user_id: user_id,
              digest: digest,
              visibility: visibility,
              document: document,
              byte_size: byte_size
            }

            %Trace{}
            |> Trace.create_changeset(attrs)
            |> Repo.insert()
            |> case do
              {:ok, trace} -> {:ok, trace, :created}
              {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
            end
        end
    end
  end

  def store(_user, _document, _options), do: {:error, :invalid_atif}

  defp valid_atif?(document) do
    version = Map.get(document, "schema_version") || Map.get(document, :schema_version)

    is_binary(version) and
      String.starts_with?(version, @atif_prefixes)
  end

  defp normalize_visibility(options, document) do
    from_options = Keyword.get(options, :visibility)
    from_document = Map.get(document, "visibility") || Map.get(document, :visibility)
    candidate = from_options || from_document || @default_visibility

    if is_binary(candidate) do
      String.trim(candidate)
    else
      @default_visibility
    end
  end
end
