defmodule OpenAgents.Chat.AccountRun do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "account_chat_runs" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    has_many :events, OpenAgents.Chat.AccountEvent, foreign_key: :run_id
    field :status, :string
    field :reasoning_effort, :string
    field :user_content, :string
    field :assistant_content, :string
    field :completion, :map
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :reasoning_effort,
      :user_content,
      :assistant_content,
      :completion,
      :error,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :conversation_id,
      :status,
      :reasoning_effort,
      :user_content,
      :started_at
    ])
    |> validate_inclusion(:status, ["streaming", "completed", "failed"])
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint(:conversation_id,
      name: :account_chat_runs_one_streaming_per_conversation
    )
  end
end
