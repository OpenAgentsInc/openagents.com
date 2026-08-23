defmodule OpenAgents.Deployments.Authority do
  @moduledoc """
  Fail-closed authorization for every deployment operation.

  Authority is decided from the principal and the durable records it names,
  never from request parameters. Four rules hold throughout:

    * Repository boundary. A grant or membership for one repository authorizes
      nothing in another, so cross-repository reads, approvals, cancellations,
      and check publications are refused before any work happens.
    * Environment boundary. A grant issued for `preview` cannot address
      `production`, even inside its own repository.
    * A workflow grant cannot widen. Its repository, environment, source ref,
      source workflow, and workflow run are compared against the bound values.
    * Platform-operator authority is not tenant authority. An operator can
      recover a stuck control-plane run, but cannot request, approve, or publish
      checks on a tenant repository, and never receives tenant secrets.

  Sensitive transitions recheck authority rather than trusting the decision made
  when the request was created: membership is revoked and policy tightens
  between `requested` and `deploying`.
  """

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Deployments.Environment
  alias OpenAgents.Deployments.Principal
  alias OpenAgents.Deployments.Protection
  alias OpenAgents.Deployments.Request
  alias OpenAgents.Deployments.Run
  alias OpenAgents.Deployments.WorkflowGrant
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @type reason ::
          :cross_repository
          | :cross_environment
          | :not_a_member
          | :not_writable
          | :not_an_approver
          | :self_approval
          | :grant_expired
          | :grant_scope
          | :source_ref_mismatch
          | :source_workflow_mismatch
          | :workflow_run_mismatch
          | :not_an_operator
          | :operator_is_not_tenant
  @type result :: :ok | {:error, {:forbidden, reason()}}

  @doc """
  Authorize reading a repository's deployment records.

  A public repository is readable by anyone who can read the repository, which
  is what visibility already means. Everything else requires membership, a grant
  bound to that repository, or platform-operator authority.
  """
  @spec authorize_read(Principal.t(), Repository.t()) :: result()
  def authorize_read(%Principal{kind: :system}, %Repository{}), do: :ok

  def authorize_read(%Principal{kind: :operator} = principal, %Repository{}),
    do: operator_check(principal)

  def authorize_read(%Principal{kind: :workflow} = principal, %Repository{} = repository),
    do: grant_repository_check(principal, repository)

  def authorize_read(%Principal{kind: :user, user: %User{} = user}, %Repository{} = repository) do
    if repository.visibility == "public" or Repositories.member?(repository, user) do
      :ok
    else
      forbidden(:not_a_member)
    end
  end

  @doc """
  Authorize creating a deployment request for one environment.

  A human needs write authority on the repository. A workflow needs a live grant
  bound to this repository and environment, carrying `deployments:request`, whose
  source ref, workflow, and workflow run match the intent it is recording. A
  platform operator is refused: fleet promotion is a separate operator API, and
  tenant deployment is not an operator power.
  """
  @spec authorize_request(Principal.t(), Repository.t(), Environment.t(), map()) :: result()
  def authorize_request(
        %Principal{kind: :user, user: %User{} = user},
        repository,
        _environment,
        _intent
      ) do
    if Repositories.writable?(repository, user), do: :ok, else: forbidden(:not_writable)
  end

  def authorize_request(%Principal{kind: :workflow} = principal, repository, environment, intent) do
    with :ok <- grant_repository_check(principal, repository),
         :ok <- grant_environment_check(principal, environment),
         :ok <- grant_live_check(principal),
         :ok <- grant_scope_check(principal, "deployments:request") do
      grant_intent_check(principal, intent)
    end
  end

  def authorize_request(%Principal{kind: :operator}, _repository, _environment, _intent),
    do: forbidden(:operator_is_not_tenant)

  def authorize_request(%Principal{kind: :system}, _repository, _environment, _intent),
    do: forbidden(:operator_is_not_tenant)

  @doc """
  Authorize publishing a check result from a trusted workflow identity.

  Only a workflow grant carrying `deployments:checks`, or a human with write
  authority, can publish. The bytes a check claims to have examined are the
  caller's to state, but the repository they belong to is not.
  """
  @spec authorize_publish_check(Principal.t(), Repository.t(), map()) :: result()
  def authorize_publish_check(%Principal{kind: :user, user: %User{} = user}, repository, _intent) do
    if Repositories.writable?(repository, user), do: :ok, else: forbidden(:not_writable)
  end

  def authorize_publish_check(%Principal{kind: :workflow} = principal, repository, intent) do
    with :ok <- grant_repository_check(principal, repository),
         :ok <- grant_live_check(principal),
         :ok <- grant_scope_check(principal, "deployments:checks") do
      grant_intent_check(principal, intent)
    end
  end

  def authorize_publish_check(%Principal{}, _repository, _intent),
    do: forbidden(:operator_is_not_tenant)

  @doc """
  Authorize an approval decision on one run.

  The approver must hold a repository role the environment admits, and must not
  be the principal that requested the deployment when the environment enforces
  separation of duties. Workflow grants cannot approve at all: a workflow that
  could approve its own deployment turns a two-party control into a one-party
  one.
  """
  @spec authorize_approval(Principal.t(), Repository.t(), Environment.t(), Request.t()) ::
          result()
  def authorize_approval(
        %Principal{kind: :user, user: %User{} = user},
        %Repository{} = repository,
        %Environment{} = environment,
        %Request{} = request
      ) do
    protection = environment.protection || %Protection{}
    role = Repositories.membership_role(repository, user)

    cond do
      is_nil(role) -> forbidden(:not_a_member)
      role not in protection.approver_roles -> forbidden(:not_an_approver)
      self_approval?(protection, request, user) -> forbidden(:self_approval)
      true -> :ok
    end
  end

  def authorize_approval(%Principal{}, _repository, _environment, _request),
    do: forbidden(:operator_is_not_tenant)

  @doc """
  Authorize cancelling a run.

  A human with write authority may cancel their repository's run. A workflow may
  cancel only a run its own grant created, so one workflow cannot cancel
  another's deployment. Cancellation is a request, not an immediate stop: the
  worker observes it and reaches a terminal state itself.
  """
  @spec authorize_cancel(Principal.t(), Repository.t(), Run.t(), Request.t()) :: result()
  def authorize_cancel(%Principal{kind: :user, user: %User{} = user}, repository, _run, _request) do
    if Repositories.writable?(repository, user), do: :ok, else: forbidden(:not_writable)
  end

  def authorize_cancel(
        %Principal{kind: :workflow} = principal,
        repository,
        _run,
        %Request{} = request
      ) do
    with :ok <- grant_repository_check(principal, repository),
         :ok <- grant_live_check(principal),
         :ok <- grant_scope_check(principal, "deployments:request") do
      if request.requested_by_grant_id == principal.grant.id do
        :ok
      else
        forbidden(:cross_repository)
      end
    end
  end

  def authorize_cancel(%Principal{kind: :operator} = principal, _repository, _run, _request),
    do: operator_check(principal)

  def authorize_cancel(%Principal{kind: :system}, _repository, _run, _request), do: :ok

  @doc """
  Authorize control-plane recovery of a stuck run.

  Recovery reconciles the control plane's own bookkeeping — expired leases,
  runs abandoned by a crashed worker — and never resolves a tenant secret or
  reports a provider outcome the provider did not report.
  """
  @spec authorize_recovery(Principal.t()) :: result()
  def authorize_recovery(%Principal{kind: :system}), do: :ok
  def authorize_recovery(%Principal{kind: :operator} = principal), do: operator_check(principal)
  def authorize_recovery(%Principal{}), do: forbidden(:not_an_operator)

  @doc "Whether this repository record belongs to this durable record's repository."
  @spec same_repository?(Repository.t(), map()) :: boolean()
  def same_repository?(%Repository{id: id}, %{repository_id: repository_id}),
    do: id == repository_id

  @doc """
  Confirm a durable record belongs to the repository the caller addressed.

  Every read path calls this after loading by id, so a valid id from another
  repository is a `cross_repository` denial rather than a successful read.
  """
  @spec check_repository(Repository.t(), map()) :: result()
  def check_repository(%Repository{} = repository, record) do
    if same_repository?(repository, record), do: :ok, else: forbidden(:cross_repository)
  end

  defp self_approval?(%Protection{separation_of_duties: false}, _request, _user), do: false

  defp self_approval?(%Protection{}, %Request{requested_by_user_id: nil}, _user), do: false

  defp self_approval?(%Protection{}, %Request{} = request, %User{id: user_id}),
    do: request.requested_by_user_id == user_id

  defp operator_check(%Principal{user: user}) do
    if Accounts.admin?(user), do: :ok, else: forbidden(:not_an_operator)
  end

  defp grant_repository_check(%Principal{grant: %WorkflowGrant{} = grant}, %Repository{} = repo) do
    if grant.repository_id == repo.id, do: :ok, else: forbidden(:cross_repository)
  end

  defp grant_repository_check(%Principal{}, %Repository{}), do: forbidden(:cross_repository)

  # A grant with no environment can address any environment in its repository;
  # a grant bound to one environment can address only that one.
  defp grant_environment_check(
         %Principal{grant: %WorkflowGrant{environment_id: nil}},
         %Environment{}
       ),
       do: :ok

  defp grant_environment_check(%Principal{grant: %WorkflowGrant{} = grant}, %Environment{} = env) do
    if grant.environment_id == env.id, do: :ok, else: forbidden(:cross_environment)
  end

  defp grant_live_check(%Principal{grant: %WorkflowGrant{} = grant}) do
    if WorkflowGrant.usable?(grant, DateTime.utc_now()), do: :ok, else: forbidden(:grant_expired)
  end

  defp grant_scope_check(%Principal{grant: %WorkflowGrant{} = grant}, scope) do
    if scope in grant.scopes, do: :ok, else: forbidden(:grant_scope)
  end

  # The intent a workflow records must match the grant it holds. Otherwise a
  # grant issued for a pull-request branch could deploy a tag, and a grant
  # issued for one workflow run could publish evidence for another.
  defp grant_intent_check(%Principal{grant: %WorkflowGrant{} = grant}, intent) do
    cond do
      mismatch?(intent, :source_ref, grant.source_ref) ->
        forbidden(:source_ref_mismatch)

      mismatch?(intent, :source_workflow, grant.source_workflow) ->
        forbidden(:source_workflow_mismatch)

      mismatch?(intent, :workflow_run_id, grant.workflow_run_id) ->
        forbidden(:workflow_run_mismatch)

      true ->
        :ok
    end
  end

  defp mismatch?(intent, key, bound) do
    case Map.get(intent, key) do
      nil -> false
      value -> value != bound
    end
  end

  defp forbidden(reason), do: {:error, {:forbidden, reason}}
end
