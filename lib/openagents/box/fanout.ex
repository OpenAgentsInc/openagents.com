defmodule OpenAgents.Box.Fanout do
  @moduledoc """
  Durable admission plans for requests that need several conversation Boxes.

  A fan-out item is a logical Box until admission succeeds. Queued items never
  call the provider and retain their position until a capacity slot opens.
  """

  import Ecto.Query

  alias OpenAgents.Box
  alias OpenAgents.Box.{ConversationBox, FanoutItem, FanoutRequest}
  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Repo

  @maximum_requested_count 100

  @type options :: [
          labels: [String.t()],
          budgeted: boolean()
        ]

  @spec admit(String.t(), map(), pos_integer(), options()) ::
          {:ok, FanoutRequest.t()} | {:error, term()}
  def admit(conversation_id, principal, count, options \\ [])
      when is_binary(conversation_id) and is_map(principal) and is_integer(count) do
    with :ok <- validate_count(count),
         owner_id when is_binary(owner_id) or is_nil(owner_id) <- owner_id(conversation_id),
         {:ok, labels} <- labels(count, Keyword.get(options, :labels)),
         {:ok, {request, labels}} <-
           create_request(conversation_id, owner_id, principal, count, options, labels) do
      request =
        labels
        |> Enum.with_index()
        |> Enum.reduce_while(request, fn {_label, position}, current ->
          case admit_item(current, position, options) do
            {:continue, updated} ->
              {:cont, updated}

            {:stop, updated, reason} ->
              queue_remaining(updated, position + 1, length(labels), reason)
              {:halt, updated}
          end
        end)

      {:ok, load_request(request.id)}
    else
      nil -> {:error, :conversation_not_found}
      error -> error
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, FanoutRequest.t()} | {:error, :not_found}
  def get(conversation_id, request_id) do
    case Repo.one(
           from request in FanoutRequest,
             where: request.id == ^request_id and request.conversation_id == ^conversation_id,
             preload: [items: ^items_query()]
         ) do
      %FanoutRequest{} = request -> {:ok, request}
      nil -> {:error, :not_found}
    end
  end

  @doc "Promotes the oldest queued logical Box when capacity permits."
  @spec promote_queued(String.t() | nil) :: :ok
  def promote_queued(conversation_id \\ nil) do
    query =
      from item in FanoutItem,
        join: request in FanoutRequest,
        on: request.id == item.request_id,
        where: item.state == "queued",
        order_by: [asc: item.queue_sequence],
        limit: 1,
        preload: [request: request]

    query =
      if is_binary(conversation_id),
        do: where(query, [item, _request], item.conversation_id == ^conversation_id),
        else: query

    case Repo.one(query) do
      %FanoutItem{} = item ->
        options = [budgeted: item.request.budgeted]
        _ = admit_item(item.request, item.position, options)
        :ok

      nil ->
        :ok
    end
  end

  defp create_request(conversation_id, owner_id, principal, count, options, labels) do
    now = now()
    budgeted = Keyword.get(options, :budgeted, false)
    limits = effective_limits(budgeted, principal)

    Repo.transaction(fn ->
      :ok = Box.lock_admission_scopes(conversation_id, owner_id)
      labels = labels || Box.next_sequential_labels(conversation_id, count)

      case ensure_labels_available(conversation_id, labels) do
        :ok ->
          request =
            %FanoutRequest{}
            |> FanoutRequest.changeset(%{
              conversation_id: conversation_id,
              requesting_principal: principal,
              requested_count: count,
              budgeted: budgeted,
              effective_limits: Map.put(limits, "owner_id", owner_id),
              inserted_at: now,
              updated_at: now
            })
            |> Repo.insert!()

          Enum.with_index(labels)
          |> Enum.each(fn {label, position} ->
            %FanoutItem{}
            |> FanoutItem.changeset(%{
              request_id: request.id,
              conversation_id: conversation_id,
              position: position,
              label: label,
              requesting_principal: principal,
              state: "queued",
              queue_reason: "admission_pending",
              estimated_burn_rate_microusd: estimated_burn_rate(),
              queued_at: now,
              inserted_at: now,
              updated_at: now
            })
            |> Repo.insert!()
          end)

          {request, labels}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp admit_item(request, position, options) do
    case Repo.one(
           from item in FanoutItem,
             where: item.request_id == ^request.id and item.position == ^position
         ) do
      %FanoutItem{state: "admitted"} ->
        {:continue, request}

      %FanoutItem{} = item ->
        case Box.create_box(item.conversation_id,
               label: item.label,
               budgeted: Keyword.get(options, :budgeted, false),
               fanout_item_id: item.id,
               estimated_burn_rate_microusd: item.estimated_burn_rate_microusd,
               conversation_burn_rate_ceiling_microusd:
                 effective_limit(request, "conversation_burn_rate_ceiling_microusd"),
               owner_burn_rate_ceiling_microusd:
                 effective_limit(request, "owner_burn_rate_ceiling_microusd")
             ) do
          {:ok, box} ->
            update_item_admitted(item, box)
            {:continue, request}

          {:error, reason} ->
            update_item_queued(item, queue_reason(reason))

            if reason in [:box_billing_required, :box_rate_limited],
              do: {:stop, request, queue_reason(reason)},
              else: {:continue, request}
        end

      nil ->
        {:continue, request}
    end
  end

  defp update_item_admitted(item, _box) do
    refresh_request(item.request_id)
  end

  defp update_item_queued(item, reason) do
    item
    |> FanoutItem.changeset(%{state: "queued", queue_reason: reason, updated_at: now()})
    |> Repo.update!()

    refresh_request(item.request_id)
  end

  defp queue_remaining(request, first_position, count, reason) do
    from(item in FanoutItem,
      where:
        item.request_id == ^request.id and item.position >= ^first_position and
          item.position < ^count and item.state == "queued"
    )
    |> Repo.update_all(set: [queue_reason: reason, updated_at: now()])

    refresh_request(request.id)
  end

  defp refresh_request(request_id) do
    counts =
      Repo.one(
        from item in FanoutItem,
          where: item.request_id == ^request_id,
          select: %{
            admitted: fragment("count(*) filter (where ? = 'admitted')", item.state),
            queued: fragment("count(*) filter (where ? = 'queued')", item.state)
          }
      )

    Repo.get!(FanoutRequest, request_id)
    |> FanoutRequest.changeset(%{
      admitted_count: counts.admitted,
      queued_count: counts.queued,
      state: if(counts.queued == 0, do: "admitted", else: "queued"),
      updated_at: now()
    })
    |> Repo.update!()
  end

  defp effective_limits(budgeted, principal) do
    %{
      "conversation_active_limit" =>
        if(budgeted, do: Box.maximum_budgeted_active_boxes(), else: Box.default_active_boxes()),
      "owner_active_limit" => Box.maximum_active_boxes_per_owner(),
      "global_active_limit" => Box.maximum_active_boxes_global(),
      "conversation_burn_rate_ceiling_microusd" =>
        configured(:maximum_burn_rate_per_conversation_microusd, 1_000_000),
      "owner_burn_rate_ceiling_microusd" =>
        configured(:maximum_burn_rate_per_owner_microusd, 5_000_000),
      "estimated_burn_rate_per_box_hour_microusd" => estimated_burn_rate(),
      "budgeted" => budgeted,
      "budgeted_by" => if(budgeted, do: principal, else: nil)
    }
  end

  defp effective_limit(request, key), do: Map.get(request.effective_limits, key, 0)

  defp estimated_burn_rate,
    do: configured(:estimated_burn_rate_per_box_hour_microusd, 100_000)

  defp configured(key, default) do
    Keyword.get(Application.get_env(:openagents, :box_api, []), key, default)
  end

  defp queue_reason(:box_quota_reached), do: "conversation_active_limit"
  defp queue_reason(:box_owner_quota_reached), do: "owner_active_limit"
  defp queue_reason(:box_global_quota_reached), do: "global_active_limit"
  defp queue_reason(:box_conversation_burn_rate_reached), do: "conversation_burn_rate_ceiling"
  defp queue_reason(:box_owner_burn_rate_reached), do: "owner_burn_rate_ceiling"
  defp queue_reason(:box_billing_required), do: "provider_billing_required"
  defp queue_reason(:box_rate_limited), do: "provider_rate_limited"
  defp queue_reason("conversation_burn_rate_ceiling"), do: "conversation_burn_rate_ceiling"
  defp queue_reason("owner_burn_rate_ceiling"), do: "owner_burn_rate_ceiling"
  defp queue_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp queue_reason(_reason), do: "admission_refused"

  defp ensure_labels_available(conversation_id, labels) do
    duplicate? = length(labels) != length(Enum.uniq(labels))

    exists? =
      Repo.exists?(
        from box in ConversationBox,
          where:
            box.conversation_id == ^conversation_id and is_nil(box.stopped_at) and
              box.label in ^labels
      ) or
        Repo.exists?(
          from item in FanoutItem,
            where:
              item.conversation_id == ^conversation_id and item.state in ["admitted", "queued"] and
                item.label in ^labels
        )

    if duplicate? or exists?, do: {:error, :box_label_taken}, else: :ok
  end

  defp labels(_count, nil), do: {:ok, nil}

  defp labels(count, labels) when is_list(labels) and length(labels) == count do
    if Enum.all?(labels, &(is_binary(&1) and String.trim(&1) != "" and byte_size(&1) <= 128)),
      do: {:ok, labels},
      else: {:error, :invalid_box_labels}
  end

  defp labels(_count, _labels), do: {:error, :invalid_box_labels}

  defp validate_count(count) when count in 1..@maximum_requested_count, do: :ok
  defp validate_count(_count), do: {:error, :invalid_box_count}

  defp owner_id(conversation_id) do
    Repo.one(
      from conversation in Conversation,
        join: visitor in assoc(conversation, :visitor),
        where: conversation.id == ^conversation_id,
        select: visitor.user_id
    )
  end

  defp load_request(request_id) do
    Repo.one!(
      from request in FanoutRequest,
        where: request.id == ^request_id,
        preload: [items: ^items_query()]
    )
  end

  defp items_query do
    from item in FanoutItem,
      order_by: [asc: item.position],
      preload: [:conversation_box]
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
