defmodule OpenAgents.Tools.Reach do
  @moduledoc """
  What a caller must already hold before a tool can succeed for them.

  A tool the caller cannot reach is not a tool. Offering it costs a provider
  round trip, a refusal the model has to read, and a turn spent explaining the
  refusal to someone who could not have acted on it. So the catalog resolves
  the caller once per turn and leaves unreachable tools out of the set the
  model is shown.

  Three requirements, declared per tool as `reach:` on its specification:

  - `:signed_in_owner` — the conversation resolves to an active account. Every
    tool that reads or acts on account-owned records needs this; without it the
    tool refuses with `owner_not_signed_in`.
  - `:paired_computer` — that account has an active paired Computer. Every tool
    that runs work *on* a Computer needs this; `computer_list` deliberately
    does not, because listing zero Computers is how the model learns to say
    "pair one first".
  - `:operator` — that account holds operator authority. `scv_deploy` spends
    our capacity rather than the caller's, so SCV-001 makes it operator-only.

  A tool with no `reach:` is reachable by anyone the scope, authority, and
  surface checks already admit — `module_discover`, conversation recall, and
  memory are reachable by any admitted conversation, and the Box tools depend
  on deployment configuration rather than on who is asking.

  This narrowing is advisory. It decides what to *offer*; it never decides what
  is *allowed*. Each tool still resolves its own owner and re-checks its own
  gate at execution (TOOL-002), so a stale catalog cannot widen authority.
  """

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.Tools.{ExecutionContext, OwnerContext, Tool}

  @requirements [:signed_in_owner, :paired_computer, :operator]

  defmodule Caller do
    @moduledoc "One turn's resolved caller authority, read once and reused."

    defstruct owner: nil, operator?: false, paired_computer?: false

    @type t :: %__MODULE__{
            owner: OpenAgents.Accounts.User.t() | nil,
            operator?: boolean(),
            paired_computer?: boolean()
          }
  end

  @doc "Every requirement a tool specification may declare."
  @spec requirements() :: [Tool.reach_requirement()]
  def requirements, do: @requirements

  @doc "A caller who holds nothing — the honest answer when no owner resolves."
  @spec unbound() :: Caller.t()
  def unbound, do: %Caller{}

  @doc """
  Resolves the caller behind an execution context.

  Goes through `OpenAgents.Tools.OwnerContext`, so the catalog and the tools
  agree about who the owner is instead of each deciding for itself.
  """
  @spec caller(ExecutionContext.t()) :: Caller.t()
  def caller(%ExecutionContext{} = context) do
    case OwnerContext.resolve(context) do
      {:ok, %User{} = user} -> owner(user)
      {:error, _unavailable} -> unbound()
    end
  end

  @doc "Resolves the caller from an account id, for surfaces holding the visitor already."
  @spec caller_for_user_id(String.t() | nil) :: Caller.t()
  def caller_for_user_id(user_id) when is_binary(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, _id} -> User |> Repo.get(user_id) |> owner()
      :error -> unbound()
    end
  end

  def caller_for_user_id(_user_id), do: unbound()

  @doc "Resolves the caller from an already-loaded account."
  @spec owner(User.t() | nil) :: Caller.t()
  def owner(%User{status: "active"} = user) do
    %Caller{
      owner: user,
      operator?: Accounts.admin?(user),
      paired_computer?: Machines.active_machine?(user.id)
    }
  end

  def owner(_user), do: unbound()

  @doc "Whether this caller holds everything the tool's `reach:` names."
  @spec reachable?(Tool.t(), Caller.t()) :: boolean()
  def reachable?(%Tool{} = tool, %Caller{} = caller), do: unmet(tool, caller) == []

  @doc "The requirements this caller does not hold, in declaration order."
  @spec unmet(Tool.t(), Caller.t()) :: [Tool.reach_requirement()]
  def unmet(%Tool{reach: reach}, %Caller{} = caller) when is_list(reach),
    do: Enum.reject(reach, &met?(&1, caller))

  def unmet(%Tool{}, %Caller{}), do: []

  defp met?(:signed_in_owner, %Caller{owner: %User{}}), do: true
  defp met?(:signed_in_owner, %Caller{}), do: false
  defp met?(:paired_computer, %Caller{paired_computer?: paired?}), do: paired?
  defp met?(:operator, %Caller{operator?: operator?}), do: operator?
  defp met?(_unknown, %Caller{}), do: false
end
