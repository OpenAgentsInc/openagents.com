defmodule OpenAgents.Box do
  @moduledoc """
  Per-conversation pool of Box VMs used as agent computers.

  Each conversation owns the boxes it creates: every read and command is
  scoped by conversation id, so one conversation can never see or drive
  another conversation's boxes. The pool caps active boxes per conversation,
  provisions with idempotency keys so a lost response cannot leave a second
  billable box, and bootstraps every new box with the OpenCode harness wired
  to the application's OpenRouter credentials through the box environment —
  the key never appears in a command line or a command log.
  """

  import Ecto.Query

  alias OpenAgents.Box.Client
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Box.FanoutItem
  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Repo
  alias OpenAgents.RuntimeConfig

  @default_active_boxes 2
  @default_maximum_active_boxes 10
  @default_ttl_seconds 3_600
  @default_poll_interval_ms 1_000
  @default_poll_attempts 30
  @runnable_states ~w(ready idle running)

  @doc "The default number of active Boxes one conversation can hold."
  @spec maximum_active_boxes() :: pos_integer()
  def maximum_active_boxes do
    default_active_boxes()
  end

  @doc "The maximum active Boxes a budgeted request can admit."
  @spec maximum_budgeted_active_boxes() :: pos_integer()
  def maximum_budgeted_active_boxes do
    settings()[:maximum_active_boxes] || @default_maximum_active_boxes
  end

  @doc "The default active-box cap before a request receives a budgeted grant."
  @spec default_active_boxes() :: pos_integer()
  def default_active_boxes do
    settings()[:default_maximum_active_boxes] || @default_active_boxes
  end

  @doc "The configured active-box cap for one owner."
  @spec maximum_active_boxes_per_owner() :: pos_integer()
  def maximum_active_boxes_per_owner do
    settings()[:maximum_active_boxes_per_owner] || 4
  end

  @doc "The configured active-box cap across all owners."
  @spec maximum_active_boxes_global() :: pos_integer()
  def maximum_active_boxes_global do
    settings()[:maximum_active_boxes_global] || 20
  end

  @doc "Lists a conversation's boxes, refreshing the state of the active ones."
  @spec list_boxes(String.t()) :: [ConversationBox.t()]
  def list_boxes(conversation_id) when is_binary(conversation_id) do
    conversation_id
    |> boxes_query()
    |> Repo.all()
    |> Enum.map(&refresh/1)
  end

  @doc "Reads one conversation-owned box, refreshing its provider state."
  @spec get_box(String.t(), String.t()) :: {:ok, ConversationBox.t()} | {:error, term()}
  def get_box(conversation_id, box_id)
      when is_binary(conversation_id) and is_binary(box_id) do
    with {:ok, record} <- fetch_owned(conversation_id, box_id) do
      {:ok, refresh(record)}
    end
  end

  @doc """
  Provisions a new box for a conversation and bootstraps OpenCode on it.

  Refuses with `:box_quota_reached` past the per-conversation cap. The create
  request carries an idempotency key, attaches no account secrets to the box
  (`noEnv`), injects the OpenRouter key as a box environment variable when the
  application holds one, and installs OpenCode through the box setup script.
  """
  @spec create_box(String.t(), keyword()) :: {:ok, ConversationBox.t()} | {:error, term()}
  def create_box(conversation_id, options \\ []) when is_binary(conversation_id) do
    transaction =
      Repo.transaction(
        fn ->
          owner_id = conversation_owner_id!(conversation_id)
          lock_admission_scopes(conversation_id, owner_id)

          label = Keyword.get(options, :label) || next_sequential_label(conversation_id)

          with :ok <- check_capacity(conversation_id, owner_id, options),
               :ok <- check_burn_rate(conversation_id, owner_id, options),
               :ok <- ensure_label_available(conversation_id, label),
               {:ok, body} <- Client.create_box(create_attributes(), Ecto.UUID.generate()),
               {:ok, box_id} <- box_id(body) do
            %ConversationBox{}
            |> ConversationBox.changeset(%{
              conversation_id: conversation_id,
              box_id: box_id,
              label: label,
              state: box_state(body)
            })
            |> Repo.insert!()
            |> persist_fanout_admission(options)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        timeout: 60_000
      )

    with {:ok, record} <- transaction do
      {:ok, await_runnable(record)}
    end
  end

  @doc """
  Runs one shell command on a conversation-owned box.

  Returns the Box command result body. A box id the conversation does not own
  refuses with `:box_not_owned` before any request leaves the host.
  """
  @spec run_command(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def run_command(conversation_id, box_id, command, timeout_seconds)
      when is_binary(conversation_id) and is_binary(box_id) and is_binary(command) and
             is_integer(timeout_seconds) do
    with {:ok, record} <- fetch_owned(conversation_id, box_id),
         :ok <- ensure_active(record) do
      Client.command(record.box_id, %{
        "command" => command,
        "timeoutSeconds" => timeout_seconds
      })
    end
  end

  @doc "Stops and archives a conversation-owned box, releasing its quota slot."
  @spec stop_box(String.t(), String.t()) :: {:ok, ConversationBox.t()} | {:error, term()}
  def stop_box(conversation_id, box_id)
      when is_binary(conversation_id) and is_binary(box_id) do
    with {:ok, record} <- fetch_owned(conversation_id, box_id),
         :ok <- ensure_active(record),
         {:ok, _body} <- Client.stop_box(record.box_id) do
      updated =
        record
        |> ConversationBox.changeset(%{state: "archiving", stopped_at: DateTime.utc_now()})
        |> Repo.update!()

      _ = OpenAgents.Box.Fanout.promote_queued(conversation_id)
      {:ok, updated}
    end
  end

  # Serializes concurrent creates for one conversation so two simultaneous
  # box_new calls cannot both pass the quota check.
  @doc false
  @spec lock_admission_scopes(String.t(), String.t() | nil) :: :ok
  def lock_admission_scopes(conversation_id, owner_id) do
    owner_key = owner_id || "anonymous:" <> conversation_id

    Enum.each(
      [
        "conversation_boxes:" <> conversation_id,
        "owner_boxes:" <> owner_key,
        "global_boxes"
      ],
      &Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [&1])
    )

    :ok
  end

  @doc false
  @spec next_sequential_labels(String.t(), pos_integer()) :: [String.t()]
  def next_sequential_labels(conversation_id, count)
      when is_binary(conversation_id) and is_integer(count) and count > 0 do
    next = next_sequential_number(conversation_id)
    Enum.map(next..(next + count - 1), &"box-#{&1}")
  end

  defp boxes_query(conversation_id) do
    from box in ConversationBox,
      where: box.conversation_id == ^conversation_id,
      order_by: [asc: box.inserted_at]
  end

  defp check_capacity(conversation_id, owner_id, options) do
    conversation_limit =
      if Keyword.get(options, :budgeted, false),
        do: maximum_budgeted_active_boxes(),
        else: default_active_boxes()

    conversation_active =
      Repo.one(
        from box in ConversationBox,
          where: box.conversation_id == ^conversation_id and is_nil(box.stopped_at),
          select: count(box.id)
      )

    owner_active =
      if is_binary(owner_id) do
        Repo.one(
          from box in ConversationBox,
            join: conversation in Conversation,
            on: conversation.id == box.conversation_id,
            join: visitor in assoc(conversation, :visitor),
            where: visitor.user_id == ^owner_id and is_nil(box.stopped_at),
            select: count(box.id)
        )
      else
        0
      end

    global_active =
      Repo.one(
        from box in ConversationBox,
          where: is_nil(box.stopped_at),
          select: count(box.id)
      )

    cond do
      conversation_active >= conversation_limit ->
        {:error, :box_quota_reached}

      owner_active >= maximum_active_boxes_per_owner() ->
        {:error, :box_owner_quota_reached}

      global_active >= maximum_active_boxes_global() ->
        {:error, :box_global_quota_reached}

      true ->
        :ok
    end
  end

  defp check_burn_rate(conversation_id, owner_id, options) do
    cost = Keyword.get(options, :estimated_burn_rate_microusd)

    if is_integer(cost) do
      conversation_burn_rate = admitted_burn_rate(conversation_id)
      owner_burn_rate = owner_admitted_burn_rate(conversation_id, owner_id)
      conversation_ceiling = Keyword.get(options, :conversation_burn_rate_ceiling_microusd)
      owner_ceiling = Keyword.get(options, :owner_burn_rate_ceiling_microusd)

      cond do
        is_integer(conversation_ceiling) and
            conversation_burn_rate + cost > conversation_ceiling ->
          {:error, :box_conversation_burn_rate_reached}

        is_integer(owner_ceiling) and owner_burn_rate + cost > owner_ceiling ->
          {:error, :box_owner_burn_rate_reached}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp admitted_burn_rate(conversation_id) do
    Repo.one(
      from item in FanoutItem,
        join: box in ConversationBox,
        on: box.id == item.conversation_box_id,
        where:
          item.conversation_id == ^conversation_id and item.state == "admitted" and
            is_nil(box.stopped_at),
        select: coalesce(sum(item.estimated_burn_rate_microusd), 0)
    )
  end

  defp owner_admitted_burn_rate(_conversation_id, owner_id) when is_binary(owner_id) do
    Repo.one(
      from item in FanoutItem,
        join: box in ConversationBox,
        on: box.id == item.conversation_box_id,
        join: conversation in Conversation,
        on: conversation.id == item.conversation_id,
        join: visitor in assoc(conversation, :visitor),
        where:
          visitor.user_id == ^owner_id and item.state == "admitted" and is_nil(box.stopped_at),
        select: coalesce(sum(item.estimated_burn_rate_microusd), 0)
    )
  end

  defp owner_admitted_burn_rate(_conversation_id, _owner_id), do: 0

  defp ensure_active(%ConversationBox{stopped_at: nil}), do: :ok
  defp ensure_active(%ConversationBox{}), do: {:error, :box_stopped}

  defp fetch_owned(conversation_id, box_id) do
    case Repo.one(
           from box in ConversationBox,
             where:
               box.conversation_id == ^conversation_id and
                 (box.box_id == ^box_id or box.label == ^box_id)
         ) do
      %ConversationBox{} = record -> {:ok, record}
      nil -> {:error, :box_not_owned}
    end
  end

  defp create_attributes do
    attributes = %{
      "ttlSeconds" => settings()[:ttl_seconds] || @default_ttl_seconds,
      "noEnv" => true,
      "setupScript" => setup_script()
    }

    case RuntimeConfig.fetch_secret(:openrouter_api_key) do
      {:ok, key} -> Map.put(attributes, "env", %{"OPENROUTER_API_KEY" => key})
      {:error, :not_configured} -> attributes
    end
  end

  # Installs the OpenCode harness and points its default model at the
  # application's configured OpenRouter model. OpenCode reads the
  # OPENROUTER_API_KEY environment variable natively, so the setup script
  # never touches the credential.
  defp setup_script do
    model = Application.get_env(:openagents, :openrouter_model, "stealth/ox-alpha")

    configuration =
      Jason.encode!(%{
        "$schema" => "https://opencode.ai/config.json",
        "model" => "openrouter/#{model}"
      })

    """
    #!/bin/bash
    set -euo pipefail
    curl -fsSL https://opencode.ai/install | bash
    mkdir -p "$HOME/.config/opencode"
    cat > "$HOME/.config/opencode/opencode.json" <<'OPENCODE_CONFIGURATION'
    #{configuration}
    OPENCODE_CONFIGURATION
    """
  end

  defp await_runnable(record) do
    attempts = settings()[:poll_attempts] || @default_poll_attempts
    interval = settings()[:poll_interval_ms] || @default_poll_interval_ms
    poll(record, attempts, interval)
  end

  defp poll(record, attempts_left, interval) do
    record = refresh(record)

    cond do
      record.state in @runnable_states and record.setup_status in ["done", "failed"] ->
        record

      record.state == "error" or attempts_left <= 0 ->
        record

      true ->
        Process.sleep(interval)
        poll(record, attempts_left - 1, interval)
    end
  end

  defp refresh(%ConversationBox{stopped_at: %DateTime{}} = record), do: record

  defp refresh(%ConversationBox{} = record) do
    case Client.get_box(record.box_id) do
      {:ok, body} ->
        record
        |> ConversationBox.changeset(%{
          state: box_state(body),
          setup_status: setup_status(body)
        })
        |> Repo.update!()

      {:error, _reason} ->
        record
    end
  end

  defp box_id(body) do
    case body do
      %{"box" => %{"id" => box_id}} when is_binary(box_id) -> {:ok, box_id}
      %{"id" => box_id} when is_binary(box_id) -> {:ok, box_id}
      _other -> {:error, :box_response_invalid}
    end
  end

  defp box_state(body) do
    state = unwrapped(body)["state"] || unwrapped(body)["status"]
    if is_binary(state) and state in ConversationBox.states(), do: state, else: "provisioning"
  end

  defp setup_status(body) do
    case unwrapped(body)["setupStatus"] do
      status when status in ["pending", "running", "done", "failed"] -> status
      _unknown -> "pending"
    end
  end

  defp unwrapped(%{"box" => %{} = box}), do: box
  defp unwrapped(%{} = body), do: body

  defp conversation_owner_id!(conversation_id) do
    Repo.one!(
      from conversation in Conversation,
        join: visitor in assoc(conversation, :visitor),
        where: conversation.id == ^conversation_id,
        select: visitor.user_id
    )
  end

  defp next_sequential_label(conversation_id) do
    "box-#{next_sequential_number(conversation_id)}"
  end

  defp next_sequential_number(conversation_id) do
    labels =
      Repo.all(
        from box in ConversationBox,
          where: box.conversation_id == ^conversation_id,
          select: box.label
      ) ++
        Repo.all(
          from item in FanoutItem,
            where: item.conversation_id == ^conversation_id,
            select: item.label
        )

    next =
      labels
      |> Enum.flat_map(fn
        <<"box-", suffix::binary>> ->
          case Integer.parse(suffix) do
            {number, ""} -> [number]
            _invalid -> []
          end

        _other ->
          []
      end)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    next
  end

  defp ensure_label_available(conversation_id, label) do
    exists? =
      Repo.exists?(
        from box in ConversationBox,
          where:
            box.conversation_id == ^conversation_id and is_nil(box.stopped_at) and
              box.label == ^label
      )

    if exists?, do: {:error, :box_label_taken}, else: :ok
  end

  defp persist_fanout_admission(record, options) do
    case Keyword.get(options, :fanout_item_id) do
      nil ->
        record

      item_id ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        Repo.update_all(
          from(item in FanoutItem, where: item.id == ^item_id),
          set: [
            state: "admitted",
            queue_reason: nil,
            conversation_box_id: record.id,
            admitted_at: now,
            updated_at: now
          ]
        )

        record
    end
  end

  defp settings, do: Application.get_env(:openagents, :box_api, [])
end
