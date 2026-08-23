defmodule OpenAgents.Deployments.Principal do
  @moduledoc """
  The authority a caller holds when it reaches the deployment control plane.

  A principal is built once, at the edge, from a credential. It is not derived
  from anything in the request body, so a caller cannot claim a repository, an
  environment, a commit, or an operator role by asserting it. Four kinds exist:

    * `:user` — a human with a repository membership and the `deployments:write`
      token scope.
    * `:workflow` — a short-lived grant bound to one repository, one source ref,
      one workflow, and one workflow run.
    * `:operator` — a platform operator, which can recover stuck control-plane
      runs but holds no tenant deployment authority.
    * `:system` — the control plane acting on itself, for worker transitions.
  """

  alias OpenAgents.Accounts.User
  alias OpenAgents.Deployments.WorkflowGrant

  @kinds [:user, :workflow, :operator, :system]

  @type kind :: :user | :workflow | :operator | :system
  @type t :: %__MODULE__{
          kind: kind(),
          user: User.t() | nil,
          grant: WorkflowGrant.t() | nil,
          worker: String.t() | nil
        }

  @enforce_keys [:kind]
  defstruct [:kind, :user, :grant, :worker]

  @doc "A human principal acting under its own repository membership."
  @spec user(User.t()) :: t()
  def user(%User{} = user), do: %__MODULE__{kind: :user, user: user}

  @doc "A workflow principal acting under a bound, short-lived grant."
  @spec workflow(WorkflowGrant.t()) :: t()
  def workflow(%WorkflowGrant{} = grant), do: %__MODULE__{kind: :workflow, grant: grant}

  @doc "A platform operator principal, holding control-plane recovery authority only."
  @spec operator(User.t()) :: t()
  def operator(%User{} = user), do: %__MODULE__{kind: :operator, user: user}

  @doc "The control plane's own principal, used for worker-driven transitions."
  @spec system(String.t()) :: t()
  def system(worker) when is_binary(worker), do: %__MODULE__{kind: :system, worker: worker}

  @doc "The principal kinds the control plane recognizes."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The principal type recorded on a durable request.

  `:system` never holds an intent, so it has no request principal type.
  """
  @spec request_principal_type(t()) :: {:ok, String.t()} | {:error, :unsupported_principal}
  def request_principal_type(%__MODULE__{kind: :user}), do: {:ok, "user"}
  def request_principal_type(%__MODULE__{kind: :workflow}), do: {:ok, "workflow"}
  def request_principal_type(%__MODULE__{kind: :operator}), do: {:ok, "operator"}
  def request_principal_type(%__MODULE__{kind: :system}), do: {:error, :unsupported_principal}

  @doc "The actor kind recorded on an event."
  @spec actor_type(t()) :: String.t()
  def actor_type(%__MODULE__{kind: kind}), do: Atom.to_string(kind)

  @doc """
  The bounded actor identifier recorded on an event.

  A grant's identifier is the grant, never its token, and a user's identifier is
  the user id, never a login that can be renamed.
  """
  @spec actor_id(t()) :: String.t() | nil
  def actor_id(%__MODULE__{kind: :workflow, grant: %WorkflowGrant{id: id}}), do: id
  def actor_id(%__MODULE__{kind: :system, worker: worker}), do: worker
  def actor_id(%__MODULE__{user: %User{id: id}}), do: id
  def actor_id(%__MODULE__{}), do: nil
end
