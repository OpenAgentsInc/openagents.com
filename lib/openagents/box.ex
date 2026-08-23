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
  alias OpenAgents.Repo
  alias OpenAgents.RuntimeConfig

  @default_maximum_active_boxes 10
  @default_ttl_seconds 3_600
  @default_poll_interval_ms 1_000
  @default_poll_attempts 30
  @runnable_states ~w(ready idle running)

  @doc "The most active boxes one conversation can hold at a time."
  @spec maximum_active_boxes() :: pos_integer()
  def maximum_active_boxes do
    settings()[:maximum_active_boxes] || @default_maximum_active_boxes
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
  @spec create_box(String.t()) :: {:ok, ConversationBox.t()} | {:error, term()}
  def create_box(conversation_id) when is_binary(conversation_id) do
    transaction =
      Repo.transaction(
        fn ->
          lock_conversation(conversation_id)

          with :ok <- check_quota(conversation_id),
               {:ok, body} <- Client.create_box(create_attributes(), Ecto.UUID.generate()),
               {:ok, box_id} <- box_id(body) do
            %ConversationBox{}
            |> ConversationBox.changeset(%{
              conversation_id: conversation_id,
              box_id: box_id,
              state: box_state(body)
            })
            |> Repo.insert!()
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
      Client.command(box_id, %{
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
         {:ok, _body} <- Client.stop_box(box_id) do
      {:ok,
       record
       |> ConversationBox.changeset(%{state: "archiving", stopped_at: DateTime.utc_now()})
       |> Repo.update!()}
    end
  end

  # Serializes concurrent creates for one conversation so two simultaneous
  # box_new calls cannot both pass the quota check.
  defp lock_conversation(conversation_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "conversation_boxes:" <> conversation_id
    ])
  end

  defp boxes_query(conversation_id) do
    from box in ConversationBox,
      where: box.conversation_id == ^conversation_id,
      order_by: [asc: box.inserted_at]
  end

  defp check_quota(conversation_id) do
    active =
      Repo.one(
        from box in ConversationBox,
          where: box.conversation_id == ^conversation_id and is_nil(box.stopped_at),
          select: count(box.id)
      )

    if active < maximum_active_boxes(), do: :ok, else: {:error, :box_quota_reached}
  end

  defp ensure_active(%ConversationBox{stopped_at: nil}), do: :ok
  defp ensure_active(%ConversationBox{}), do: {:error, :box_stopped}

  defp fetch_owned(conversation_id, box_id) do
    case Repo.one(
           from box in ConversationBox,
             where: box.conversation_id == ^conversation_id and box.box_id == ^box_id
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

  defp settings, do: Application.get_env(:openagents, :box_api, [])
end
