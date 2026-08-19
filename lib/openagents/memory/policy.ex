defmodule OpenAgents.Memory.Policy do
  @moduledoc "Host-owned, versioned admission policy for profile-memory claims."

  import Ecto.Query

  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Memory.{PolicyEvent, Redaction}
  alias OpenAgents.Repo

  @version "sarah.memory.policy.v1"
  @reason_codes ~w(
    credential_material api_token wallet_seed_material payment_material
    authentication_secret local_path encoded_secret_material
  )

  @spec version() :: String.t()
  def version, do: @version

  @spec admit_candidate(Visitor.t(), String.t(), String.t()) ::
          :ok | {:error, {:memory_policy_rejected, String.t()} | :policy_audit_unavailable}
  def admit_candidate(%Visitor{} = owner, category, claim)
      when is_binary(category) and is_binary(claim) do
    case Redaction.classify(claim) do
      :safe ->
        :ok

      {:reject, reason} ->
        reason_code = Atom.to_string(reason)

        case record_rejection(owner, category, reason_code, claim) do
          {:ok, _event} -> {:error, {:memory_policy_rejected, reason_code}}
          {:error, _changeset} -> {:error, :policy_audit_unavailable}
        end
    end
  end

  def admit_candidate(_owner, _category, _claim), do: {:error, :policy_audit_unavailable}

  @spec admit_metadata(Visitor.t(), String.t(), term()) ::
          :ok | {:error, {:memory_policy_rejected, String.t()} | :policy_audit_unavailable}
  def admit_metadata(%Visitor{} = owner, category, metadata) do
    metadata
    |> string_values()
    |> Enum.reduce_while(:ok, fn value, :ok ->
      case admit_candidate(owner, category, value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec list_rejections(Visitor.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def list_rejections(owner, options \\ [])

  def list_rejections(%Visitor{id: owner_id}, options) do
    limit = Keyword.get(options, :limit, 100)

    if is_integer(limit) and limit in 1..100 do
      events =
        Repo.all(
          from(event in PolicyEvent,
            where: event.owner_visitor_id == ^owner_id,
            order_by: [desc: event.inserted_at, desc: event.id],
            limit: ^limit
          )
        )

      {:ok,
       Enum.map(events, fn event ->
         %{
           "id" => event.id,
           "policy_version" => event.policy_version,
           "outcome" => event.outcome,
           "reason_code" => event.reason_code,
           "category" => event.category,
           "input_size_bucket" => event.input_size_bucket,
           "recorded_at" => DateTime.to_iso8601(event.inserted_at)
         }
       end)}
    else
      {:error, :invalid_limit}
    end
  end

  def list_rejections(_owner, _options), do: {:error, :invalid_owner_scope}

  defp record_rejection(owner, category, reason_code, claim)
       when reason_code in @reason_codes do
    PolicyEvent.changeset(%PolicyEvent{owner_visitor_id: owner.id}, %{
      policy_version: @version,
      outcome: "rejected",
      reason_code: reason_code,
      category: category,
      input_size_bucket: size_bucket(byte_size(claim)),
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp size_bucket(size) when size <= 64, do: "1-64"
  defp size_bucket(size) when size <= 128, do: "65-128"
  defp size_bucket(size) when size <= 256, do: "129-256"
  defp size_bucket(size) when size <= 500, do: "257-500"
  defp size_bucket(_size), do: "over-500"

  defp string_values(value) when is_binary(value), do: [value]

  defp string_values(value) when is_list(value),
    do: Enum.flat_map(value, &string_values/1)

  defp string_values(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} -> string_values(key) ++ string_values(nested) end)
  end

  defp string_values(_value), do: []
end
