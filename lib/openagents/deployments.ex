defmodule OpenAgents.Deployments do
  @moduledoc """
  The deployment control plane: one place that decides whether exact bytes may
  reach a repository's environment, and records why.

  ## What this context owns

    * Repository-scoped environments and their protection policy.
    * Durable deployment requests: an intent for one exact commit and artifact.
    * Durable runs: the admitted execution of one request, with a lifecycle no
      caller can shortcut.
    * Approvals, check results, and an append-only event stream.

  ## The rules that hold everywhere

    * Authority comes from the principal, never from the request body. See
      `OpenAgents.Deployments.Authority`.
    * Every transition is checked against `OpenAgents.Deployments.Lifecycle` and
      written transactionally with its event, so a run's state and its history
      cannot disagree.
    * Policy is re-evaluated, and authority re-checked, at sensitive transitions.
      Membership is revoked and environments freeze between `requested` and
      `deploying`.
    * A request is idempotent on `{repository, environment, idempotency_key}`.
      Replaying a key with the same bytes returns the original run; replaying it
      with different bytes is a conflict, not a second deployment.
    * Durable records hold secret *references*. Values are resolved at execution
      time, for the bound provider and environment, and never stored.
    * Platform-operator authority recovers the control plane. It does not deploy
      tenant code, and `deployments:promote` — the Forge fleet promotion scope —
      is never exposed to a repository workflow.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.Accounts.User
  alias OpenAgents.Deployments.Approval
  alias OpenAgents.Deployments.Authority
  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Deployments.Environment
  alias OpenAgents.Deployments.Event
  alias OpenAgents.Deployments.Lifecycle
  alias OpenAgents.Deployments.Policy
  alias OpenAgents.Deployments.Principal
  alias OpenAgents.Deployments.Protection
  alias OpenAgents.Deployments.Provider
  alias OpenAgents.Deployments.Request
  alias OpenAgents.Deployments.Run
  alias OpenAgents.Deployments.WorkflowGrant
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository

  @default_limit 25
  @maximum_limit 100
  @default_lease_seconds 300

  @type error ::
          {:forbidden, Authority.reason()}
          | :environment_not_found
          | :run_not_found
          | :request_not_found
          | :unknown_provider
          | :unknown_commit
          | :idempotency_conflict
          | :precondition_failed
          | {:illegal_transition, String.t(), String.t()}
          | {:policy_denied, String.t()}
          | Ecto.Changeset.t()

  # ---------------------------------------------------------------------------
  # Environments
  # ---------------------------------------------------------------------------

  @doc """
  Define or replace one environment's provider binding and protection policy.

  Only a repository member with write authority can define an environment, and
  the provider must be one the platform configures: a tenant that could name an
  arbitrary module would choose which code the control plane runs.
  """
  @spec put_environment(Repository.t(), Principal.t(), map()) ::
          {:ok, Environment.t()} | {:error, error()}
  def put_environment(%Repository{} = repository, %Principal{} = principal, attrs) do
    attrs = normalize(attrs)

    with :ok <- authorize_write(principal, repository),
         {:ok, _module} <- Provider.fetch(attrs["provider"] || "") do
      name = attrs["name"]

      environment =
        case fetch_environment_record(repository, name) do
          {:ok, existing} -> existing
          {:error, :environment_not_found} -> %Environment{repository_id: repository.id}
        end

      environment
      |> Environment.changeset(Map.put_new(attrs, "protection", %{}))
      |> put_creator(principal, environment)
      |> Repo.insert_or_update()
    end
  end

  @doc "List one repository's environments, with their protection requirements."
  @spec list_environments(Repository.t(), Principal.t()) ::
          {:ok, [Environment.t()]} | {:error, error()}
  def list_environments(%Repository{} = repository, %Principal{} = principal) do
    with :ok <- Authority.authorize_read(principal, repository) do
      {:ok,
       Repo.all(
         from environment in Environment,
           where: environment.repository_id == ^repository.id,
           order_by: [asc: environment.name]
       )}
    end
  end

  @doc "Fetch one environment by name, enforcing repository visibility."
  @spec fetch_environment(Repository.t(), Principal.t(), String.t()) ::
          {:ok, Environment.t()} | {:error, error()}
  def fetch_environment(%Repository{} = repository, %Principal{} = principal, name) do
    with :ok <- Authority.authorize_read(principal, repository) do
      fetch_environment_record(repository, name)
    end
  end

  # ---------------------------------------------------------------------------
  # Requests and runs
  # ---------------------------------------------------------------------------

  @doc """
  Record a deployment intent and admit it as far as policy allows.

  The request names exact bytes: a full commit sha and an artifact digest. The
  commit is verified against the repository's own git storage through
  `:commit_store`, so a request cannot deploy a sha the repository never
  received.

  On success the run holds the furthest state policy admits: `queued` when
  nothing is outstanding, `checking` while required checks are missing,
  `waiting_for_approval` while approvals are. A policy denial is durable too: the
  run reaches `failed` with an explanation, because a deployment that was refused
  and left no record is indistinguishable from one that was never asked for.
  """
  @spec request_deployment(Repository.t(), Principal.t(), map(), keyword()) ::
          {:ok, Run.t()} | {:error, error()}
  def request_deployment(
        %Repository{} = repository,
        %Principal{} = principal,
        attrs,
        options \\ []
      ) do
    attrs = normalize(attrs)
    commit_store = Keyword.get_lazy(options, :commit_store, &default_commit_store/0)

    with {:ok, environment} <- fetch_environment_record(repository, attrs["environment"]),
         {:ok, principal_type} <- Principal.request_principal_type(principal),
         intent = intent(attrs),
         :ok <- Authority.authorize_request(principal, repository, environment, intent),
         {:ok, provider} <- Provider.fetch(environment.provider),
         :ok <- verify_commit(repository, attrs["commit_sha"], commit_store),
         {:ok, request} <-
           insert_request(repository, environment, principal, principal_type, attrs) do
      case Repo.preload(request, :run) do
        %Request{run: %Run{} = run} -> {:ok, run}
        %Request{} -> admit(repository, environment, request, principal, provider)
      end
    end
  end

  @doc """
  Fetch one run by id, enforcing repository visibility and boundary.

  A valid run id from another repository is a `cross_repository` denial rather
  than a successful read.
  """
  @spec fetch_run(Repository.t(), Principal.t(), String.t()) ::
          {:ok, Run.t()} | {:error, error()}
  def fetch_run(%Repository{} = repository, %Principal{} = principal, id) do
    with :ok <- Authority.authorize_read(principal, repository),
         {:ok, run} <- fetch_run_record(id),
         :ok <- Authority.check_repository(repository, run) do
      {:ok, Repo.preload(run, [:deployment_request, :environment])}
    end
  end

  @doc """
  List a repository's runs, newest first, with bounded keyset pagination.

  `:limit` is clamped to #{@maximum_limit}, and `:cursor` is the id of the last
  run a caller has already seen.
  """
  @spec list_runs(Repository.t(), Principal.t(), keyword()) ::
          {:ok, [Run.t()]} | {:error, error()}
  def list_runs(%Repository{} = repository, %Principal{} = principal, options \\ []) do
    with :ok <- Authority.authorize_read(principal, repository) do
      query =
        from run in Run,
          where: run.repository_id == ^repository.id,
          order_by: [desc: run.inserted_at, desc: run.id],
          limit: ^limit(options),
          preload: [:deployment_request, :environment]

      query =
        case cursor_run(repository, options[:cursor]) do
          nil ->
            query

          %Run{} = cursor ->
            from run in query,
              where:
                run.inserted_at < ^cursor.inserted_at or
                  (run.inserted_at == ^cursor.inserted_at and run.id < ^cursor.id)
        end

      query =
        case options[:environment_id] do
          nil -> query
          environment_id -> from run in query, where: run.environment_id == ^environment_id
        end

      query =
        case options[:state] do
          nil -> query
          state -> from run in query, where: run.state == ^state
        end

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  Request cancellation of a run.

  Cancellation is bounded, not immediate. A run that has not reached the provider
  cancels at once. A run already `deploying` records the request, and the worker
  that holds the lease drives it to a terminal state itself, so the control plane
  never claims a deployment stopped because someone asked.
  """
  @spec cancel_run(Repository.t(), Principal.t(), String.t(), keyword()) ::
          {:ok, Run.t()} | {:error, error()}
  def cancel_run(%Repository{} = repository, %Principal{} = principal, id, options \\ []) do
    with {:ok, run} <- fetch_run_record(id),
         :ok <- Authority.check_repository(repository, run),
         {:ok, request} <- fetch_request_record(run.deployment_request_id),
         :ok <- Authority.authorize_cancel(principal, repository, run, request),
         :ok <- precondition(run, options) do
      cancel = fn ->
        run
        |> Ecto.Changeset.change(%{
          cancel_requested_at: DateTime.utc_now(),
          cancel_requested_by_user_id: cancel_requester(principal)
        })
        |> Repo.update()
      end

      cond do
        Run.terminal?(run) ->
          {:error, {:illegal_transition, run.state, "cancelled"}}

        run.state == "deploying" ->
          with {:ok, run} <- cancel.() do
            {:ok, _event} = append_event(run, "cancellation_requested", principal, %{})
            {:ok, run}
          end

        true ->
          with {:ok, run} <- cancel.() do
            transition(run, "cancelled", principal, reason: "cancelled_by_request")
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Approvals
  # ---------------------------------------------------------------------------

  @doc """
  Record an approval decision and re-evaluate the run.

  The decision is bound to the request digest it was made against, so it cannot
  carry onto different bytes. The approver must hold a role the environment
  admits and, under separation of duties, must not be the requester.
  """
  @spec decide_run(Repository.t(), Principal.t(), String.t(), String.t(), map()) ::
          {:ok, Run.t()} | {:error, error()}
  def decide_run(%Repository{} = repository, %Principal{} = principal, id, decision, attrs \\ %{})
      when decision in ~w(approved rejected) do
    attrs = normalize(attrs)

    with {:ok, run} <- fetch_run_record(id),
         :ok <- Authority.check_repository(repository, run),
         {:ok, request} <- fetch_request_record(run.deployment_request_id),
         {:ok, environment} <- fetch_environment_by_id(repository, run.environment_id),
         :ok <- Authority.authorize_approval(principal, repository, environment, request),
         :ok <- approvable(run) do
      %Approval{
        repository_id: repository.id,
        deployment_run_id: run.id,
        approver_user_id: principal.user.id,
        rule: "required_approvals",
        request_digest: request.request_digest,
        decided_at: DateTime.utc_now()
      }
      |> Approval.changeset(Map.put(attrs, "decision", decision))
      |> Repo.insert()
      |> case do
        {:ok, _approval} ->
          {:ok, _event} =
            append_event(run, "approval_recorded", principal, %{"decision" => decision})

          reevaluate(repository, environment, request, run, principal)

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "List the decisions recorded against one run."
  @spec list_approvals(Repository.t(), Principal.t(), Run.t()) ::
          {:ok, [Approval.t()]} | {:error, error()}
  def list_approvals(%Repository{} = repository, %Principal{} = principal, %Run{} = run) do
    with :ok <- Authority.authorize_read(principal, repository),
         :ok <- Authority.check_repository(repository, run) do
      {:ok,
       Repo.all(
         from approval in Approval,
           where: approval.deployment_run_id == ^run.id,
           order_by: [asc: approval.decided_at]
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Check results
  # ---------------------------------------------------------------------------

  @doc """
  Publish a check result for exact bytes, from a trusted identity.

  Identity is `{repository, name, commit, artifact}`. Publishing the same name
  for different bytes writes a new row, so a green result can never be replayed
  onto an artifact it did not examine. Republishing the same bytes updates that
  one row, which is how a `pending` check becomes `succeeded`.

  Every run in `checking` for those bytes is re-evaluated afterwards, so evidence
  arriving is what moves a run forward.
  """
  @spec publish_check_result(Repository.t(), Principal.t(), map()) ::
          {:ok, CheckResult.t()} | {:error, error()}
  def publish_check_result(%Repository{} = repository, %Principal{} = principal, attrs) do
    attrs = normalize(attrs)

    with :ok <- Authority.authorize_publish_check(principal, repository, intent(attrs)) do
      existing =
        Repo.one(
          from result in CheckResult,
            where:
              result.repository_id == ^repository.id and result.name == ^to_string(attrs["name"]) and
                result.commit_sha == ^String.downcase(to_string(attrs["commit_sha"])) and
                result.artifact_digest == ^to_string(attrs["artifact_digest"])
        ) || %CheckResult{repository_id: repository.id}

      existing
      |> CheckResult.changeset(attrs)
      |> put_publisher(principal)
      |> Repo.insert_or_update()
      |> case do
        {:ok, result} ->
          # The qualification receipt for an issue's evidence chain. It is
          # repository-scoped and binds the exact commit and artifact, so it
          # resolves to an issue without a priced claim standing behind it.
          _ = OpenAgents.Issues.Evidence.record_check_result(result)
          reevaluate_checking_runs(repository, result, principal)
          {:ok, result}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "List the check results published for one repository's exact bytes."
  @spec list_check_results(Repository.t(), Principal.t(), String.t(), String.t()) ::
          {:ok, [CheckResult.t()]} | {:error, error()}
  def list_check_results(
        %Repository{} = repository,
        %Principal{} = principal,
        commit_sha,
        artifact
      ) do
    with :ok <- Authority.authorize_read(principal, repository) do
      {:ok, check_results(repository, commit_sha, artifact)}
    end
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @doc """
  List a run's events after a cursor, for polling or streaming.

  The sequence is per-run and monotonic, so a reader that remembers the last
  sequence it saw can resume without gaps or duplicates.
  """
  @spec list_events(Repository.t(), Principal.t(), Run.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, error()}
  def list_events(
        %Repository{} = repository,
        %Principal{} = principal,
        %Run{} = run,
        options \\ []
      ) do
    with :ok <- Authority.authorize_read(principal, repository),
         :ok <- Authority.check_repository(repository, run) do
      after_sequence = Keyword.get(options, :after_sequence, 0)

      {:ok,
       Repo.all(
         from event in Event,
           where: event.deployment_run_id == ^run.id and event.sequence > ^after_sequence,
           order_by: [asc: event.sequence],
           limit: ^limit(options)
       )}
    end
  end

  @doc "The topic a subscriber follows for one run's committed events."
  @spec run_topic(Run.t() | String.t()) :: String.t()
  def run_topic(%Run{id: id}), do: run_topic(id)
  def run_topic(id) when is_binary(id), do: "deployments:run:" <> id

  @doc """
  Subscribe to one run's events.

  Broadcasts happen after the transaction commits, so a subscriber never sees a
  transition that later disappears.
  """
  @spec subscribe(Run.t() | String.t()) :: :ok | {:error, term()}
  def subscribe(run), do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, run_topic(run))

  # ---------------------------------------------------------------------------
  # Workflow grants
  # ---------------------------------------------------------------------------

  @doc """
  Issue a short-lived workflow grant bound to one run of one workflow.

  The plaintext token is returned once and never stored. The grant carries the
  repository, the optional environment, the source ref, the workflow, and the
  workflow run it was issued for; authorization compares a request against those
  bound values rather than against anything the caller sends.
  """
  @spec issue_workflow_grant(Repository.t(), Principal.t(), map()) ::
          {:ok, {WorkflowGrant.t(), String.t()}} | {:error, error()}
  def issue_workflow_grant(%Repository{} = repository, %Principal{} = principal, attrs) do
    attrs = normalize(attrs)

    with :ok <- authorize_write(principal, repository),
         {:ok, environment_id} <- grant_environment_id(repository, attrs["environment"]) do
      plaintext = "oa_wfg_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      lifetime = grant_lifetime(attrs["lifetime_seconds"])

      %WorkflowGrant{
        repository_id: repository.id,
        environment_id: environment_id,
        token_digest: digest(plaintext),
        expires_at: DateTime.add(DateTime.utc_now(), lifetime, :second),
        created_by_user_id: principal.user.id
      }
      |> WorkflowGrant.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, grant} -> {:ok, {grant, plaintext}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Authenticate a workflow grant token into a principal.

  Only a live, unrevoked grant authenticates, and only the digest is compared, so
  a database read cannot recover a usable token.
  """
  @spec authenticate_workflow_grant(String.t()) ::
          {:ok, Principal.t()} | {:error, :invalid_grant}
  def authenticate_workflow_grant("oa_wfg_" <> _rest = plaintext)
      when byte_size(plaintext) < 160 do
    grant = Repo.one(from g in WorkflowGrant, where: g.token_digest == ^digest(plaintext))

    if grant && WorkflowGrant.usable?(grant, DateTime.utc_now()) do
      {:ok, Principal.workflow(grant)}
    else
      {:error, :invalid_grant}
    end
  end

  def authenticate_workflow_grant(_plaintext), do: {:error, :invalid_grant}

  @doc "Revoke a grant before it expires."
  @spec revoke_workflow_grant(Repository.t(), Principal.t(), String.t()) ::
          {:ok, WorkflowGrant.t()} | {:error, error()}
  def revoke_workflow_grant(%Repository{} = repository, %Principal{} = principal, id) do
    with :ok <- authorize_write(principal, repository),
         %WorkflowGrant{} = grant <- Repo.get(WorkflowGrant, id),
         :ok <- Authority.check_repository(repository, grant) do
      grant
      |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now()})
      |> Repo.update()
    else
      nil -> {:error, :run_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Worker surface
  # ---------------------------------------------------------------------------

  @doc """
  Claim the next queued run for execution, taking a lease.

  The claim is a single conditional update, so two workers racing for one run
  produce one winner and one `nil`: this is what keeps a provider from executing
  the same run twice.
  """
  @spec claim_run(String.t(), keyword()) :: {:ok, Run.t()} | :empty
  def claim_run(worker, options \\ []) when is_binary(worker) do
    lease_seconds = Keyword.get(options, :lease_seconds, @default_lease_seconds)
    now = Keyword.get(options, :now, DateTime.utc_now())
    expires_at = DateTime.add(now, lease_seconds, :second)

    candidate =
      Repo.one(
        from run in Run,
          where: run.state == "queued",
          where: is_nil(run.lease_expires_at) or run.lease_expires_at < ^now,
          order_by: [asc: run.inserted_at],
          limit: 1,
          select: run.id
      )

    case candidate && claim(candidate, worker, expires_at, now) do
      nil ->
        :empty

      {1, [%Run{} = run]} ->
        {:ok, _event} =
          append_event(run, "lease_acquired", Principal.system(worker), %{"worker" => worker})

        {:ok, run}

      {0, _runs} ->
        :empty
    end
  end

  @doc """
  Extend the lease a worker holds on a run.

  A worker that cannot renew has lost the run, and must stop rather than keep
  deploying: the renewal returning `:error` is the signal.
  """
  @spec renew_lease(Run.t(), String.t(), keyword()) :: {:ok, Run.t()} | :error
  def renew_lease(%Run{} = run, worker, options \\ []) do
    lease_seconds = Keyword.get(options, :lease_seconds, @default_lease_seconds)
    expires_at = DateTime.add(DateTime.utc_now(), lease_seconds, :second)

    {count, runs} =
      Repo.update_all(
        from(r in Run,
          where: r.id == ^run.id and r.lease_owner == ^worker and r.state == ^run.state,
          select: r
        ),
        set: [lease_expires_at: expires_at, updated_at: DateTime.utc_now()]
      )

    case {count, runs} do
      {1, [%Run{} = renewed]} -> {:ok, renewed}
      _lost -> :error
    end
  end

  @doc """
  Reclaim runs whose worker died holding a lease.

  Recovery is deliberately narrow. A run that had not reached the provider goes
  back to `queued` to be executed by another worker. A run that was already
  `deploying` does *not*: the control plane does not know what the provider did,
  so the run fails with an explicitly uncertain reason. Guessing `succeeded`
  reports a deployment that may not exist, and guessing a clean retry can deploy
  twice.
  """
  @spec reconcile_leases(Principal.t(), keyword()) ::
          {:ok, %{requeued: integer(), uncertain: integer()}} | {:error, error()}
  def reconcile_leases(%Principal{} = principal, options \\ []) do
    with :ok <- Authority.authorize_recovery(principal) do
      now = Keyword.get(options, :now, DateTime.utc_now())

      requeued = release_expired(now, principal)
      uncertain = fail_uncertain(now, principal)

      {:ok, %{requeued: requeued, uncertain: uncertain}}
    end
  end

  @doc """
  Record the provider's outcome for a run the worker holds.

  Only three outcomes exist, and the third is why this function is narrow:
  `{:uncertain, receipt}` writes `failed` with the reason
  `provider_result_uncertain` rather than a success receipt. The control plane
  never upgrades "I don't know" to "it worked".
  """
  @spec finish_run(Run.t(), String.t(), Provider.result(), keyword()) ::
          {:ok, Run.t()} | {:error, error()}
  def finish_run(%Run{} = run, worker, result, options \\ []) do
    principal = Principal.system(worker)
    secret_values = Keyword.get(options, :secret_values, [])

    # A cancellation requested while the provider was running is honored here,
    # after the provider reported, so the run's terminal state reflects what the
    # provider actually did rather than what the canceller hoped.
    cancelled? = not is_nil(run.cancel_requested_at)

    case result do
      {:ok, receipt} when cancelled? ->
        transition(run, "cancelled", principal,
          reason: "cancelled_after_provider_success",
          receipt: receipt,
          secret_values: secret_values,
          finished: true
        )

      {:ok, receipt} ->
        transition(run, "succeeded", principal,
          receipt: receipt,
          secret_values: secret_values,
          finished: true
        )

      {:error, reason} when cancelled? ->
        transition(run, "cancelled", principal,
          reason: bounded_reason(reason),
          finished: true
        )

      {:error, reason} ->
        transition(run, "failed", principal,
          reason: bounded_reason(reason),
          finished: true
        )

      {:uncertain, receipt} ->
        transition(run, "failed", principal,
          reason: "provider_result_uncertain",
          receipt: receipt,
          secret_values: secret_values,
          finished: true
        )
    end
  end

  @doc """
  Move a run to `state`, transactionally, with its event.

  This is the only writer of `Run.state`. It checks the transition against
  `OpenAgents.Deployments.Lifecycle`, compares the state it read against the row
  it updates so a concurrent transition cannot be lost, and appends the event in
  the same transaction. A state without a matching event, or an event without a
  state change, would each make the history a guess.
  """
  @spec transition(Run.t(), String.t(), Principal.t(), keyword()) ::
          {:ok, Run.t()} | {:error, error()}
  def transition(%Run{} = run, state, %Principal{} = principal, options \\ []) do
    with :ok <- Lifecycle.check(run.state, state) do
      now = DateTime.utc_now()
      finished = Keyword.get(options, :finished, state in Run.terminal_states())

      changes =
        %{state: state, updated_at: now}
        |> maybe_put(:result_reason, Keyword.get(options, :reason))
        |> maybe_put(
          :provider_receipt,
          case Keyword.get(options, :receipt) do
            nil ->
              nil

            receipt ->
              Provider.sanitize_receipt(receipt, Keyword.get(options, :secret_values, []))
          end
        )
        |> maybe_put(:policy_explanation, Keyword.get(options, :explanation))
        |> maybe_put(:superseded_by_run_id, Keyword.get(options, :superseded_by_run_id))
        |> maybe_put(:started_at, if(state == "deploying", do: now))
        |> maybe_put(:finished_at, if(finished, do: now))
        |> maybe_put(:lease_owner, if(finished, do: :nil_value))
        |> maybe_put(:lease_expires_at, if(finished, do: :nil_value))

      Multi.new()
      |> Multi.run(:run, fn repo, _changes ->
        {count, runs} =
          repo.update_all(
            from(r in Run, where: r.id == ^run.id and r.state == ^run.state, select: r),
            set: Enum.map(changes, fn {key, value} -> {key, denil(value)} end)
          )

        case {count, runs} do
          {1, [%Run{} = updated]} -> {:ok, updated}
          _stale -> {:error, :precondition_failed}
        end
      end)
      |> Multi.run(:event, fn repo, %{run: updated} ->
        insert_event(
          repo,
          updated,
          Keyword.get(options, :event_type, "state_changed"),
          principal,
          Map.merge(
            %{"reason" => Keyword.get(options, :reason)},
            Keyword.get(options, :detail, %{})
          ),
          from: run.state,
          to: state
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{run: updated, event: event}} ->
          broadcast(updated, event)

          # A terminal run is the tenant plane's deployment receipt. Failed,
          # cancelled, and superseded runs record their edge exactly as a
          # succeeded one does; nothing is deleted to tidy a timeline.
          if finished, do: OpenAgents.Issues.Evidence.record_deployment_run(updated)

          {:ok, updated}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Re-evaluate policy for a run that is waiting, re-checking authority first.

  Called when evidence arrives, when a decision is recorded, and before a worker
  hands a run to a provider. A run admitted an hour ago is not admitted now if
  the environment froze, the window closed, or the requester lost membership.
  """
  @spec reevaluate(Repository.t(), Environment.t(), Request.t(), Run.t(), Principal.t()) ::
          {:ok, Run.t()} | {:error, error()}
  def reevaluate(
        %Repository{} = repository,
        %Environment{} = environment,
        %Request{} = request,
        %Run{} = run,
        %Principal{} = principal
      ) do
    approvals =
      Repo.all(from approval in Approval, where: approval.deployment_run_id == ^run.id)

    checks = check_results(repository, request.commit_sha, request.artifact_digest)

    case Policy.evaluate(environment, request, checks, approvals, DateTime.utc_now()) do
      {:admit, state, explanation} ->
        if state == run.state do
          {:ok, store_explanation(run, explanation)}
        else
          transition(run, state, principal,
            explanation: explanation,
            event_type: "policy_evaluated"
          )
        end

      {:deny, reason, explanation} ->
        transition(run, "failed", principal,
          reason: reason,
          explanation: explanation,
          event_type: "policy_denied"
        )
    end
  end

  @doc """
  Re-check the authority behind a request at a sensitive transition.

  Membership is revoked, roles change, and grants expire between `requested` and
  `deploying`. The check reruns against the durable request rather than the
  original credential, because the original credential is long gone by then.
  """
  @spec recheck_request_authority(Repository.t(), Environment.t(), Request.t()) ::
          :ok | {:error, error()}
  def recheck_request_authority(
        %Repository{} = repository,
        %Environment{} = environment,
        %Request{} = request
      ) do
    case request.principal_type do
      "user" ->
        case Repo.get(User, request.requested_by_user_id) do
          %User{} = user ->
            Authority.authorize_request(Principal.user(user), repository, environment, %{})

          nil ->
            {:error, {:forbidden, :not_a_member}}
        end

      "workflow" ->
        case Repo.get(WorkflowGrant, request.requested_by_grant_id) do
          %WorkflowGrant{} = grant ->
            Authority.authorize_request(
              Principal.workflow(grant),
              repository,
              environment,
              %{}
            )

          nil ->
            {:error, {:forbidden, :grant_expired}}
        end

      _other ->
        {:error, {:forbidden, :operator_is_not_tenant}}
    end
  end

  @doc "Build the execution a provider receives, resolving secrets for this attempt."
  @spec build_execution(Repository.t(), Environment.t(), Request.t(), Run.t(), keyword()) ::
          {:ok, OpenAgents.Deployments.Execution.t()} | {:error, error()}
  def build_execution(
        %Repository{} = repository,
        %Environment{} = environment,
        %Request{} = request,
        %Run{} = run,
        options \\ []
      ) do
    with {:ok, module} <- Provider.fetch(environment.provider),
         references = module.required_secret_references(environment.provider_config),
         {:ok, secrets} <- OpenAgents.Deployments.SecretResolver.resolve(environment, references) do
      {:ok,
       %OpenAgents.Deployments.Execution{
         run_id: run.id,
         repository: repository.owner <> "/" <> repository.name,
         environment: environment.name,
         commit_sha: request.commit_sha,
         artifact_digest: request.artifact_digest,
         input_digest: run.input_digest,
         attempt: run.attempt_count + 1,
         deadline:
           DateTime.add(DateTime.utc_now(), Keyword.get(options, :timeout_seconds, 600), :second),
         provider_config: environment.provider_config,
         secrets: secrets
       }}
    end
  end

  @doc "Load the repository, environment, and request a run belongs to."
  @spec load_run_context(Run.t()) ::
          {:ok, {Repository.t(), Environment.t(), Request.t()}} | {:error, error()}
  def load_run_context(%Run{} = run) do
    with %Repository{} = repository <- Repo.get(Repository, run.repository_id),
         %Environment{} = environment <- Repo.get(Environment, run.environment_id),
         {:ok, request} <- fetch_request_record(run.deployment_request_id) do
      {:ok, {repository, environment, request}}
    else
      nil -> {:error, :run_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Admission
  # ---------------------------------------------------------------------------

  defp admit(repository, environment, request, principal, _provider) do
    protection = environment.protection || %Protection{}

    with {:ok, run} <- insert_run(repository, environment, request),
         {:ok, run} <- apply_concurrency(repository, environment, protection, run, principal) do
      reevaluate(repository, environment, request, run, principal)
    end
  end

  defp insert_run(repository, environment, request) do
    run = %Run{
      repository_id: repository.id,
      environment_id: environment.id,
      deployment_request_id: request.id,
      input_digest: request.input_digest,
      provider: environment.provider
    }

    Multi.new()
    |> Multi.insert(
      :run,
      Run.changeset(run, %{state: Policy.initial_state(environment)})
    )
    |> Multi.run(:event, fn repo, %{run: inserted} ->
      insert_event(repo, inserted, "run_created", Principal.system("control_plane"), %{},
        to: inserted.state
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run, event: event}} ->
        broadcast(run, event)
        {:ok, run}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Concurrency is per environment and never crosses environments: superseding a
  # preview deployment must not supersede production, so candidates are selected
  # by environment id alone.
  defp apply_concurrency(
         _repository,
         _environment,
         %Protection{concurrency: "queue"},
         run,
         _principal
       ),
       do: {:ok, run}

  defp apply_concurrency(_repository, environment, %Protection{concurrency: mode}, run, principal) do
    others =
      Repo.all(
        from other in Run,
          where:
            other.environment_id == ^environment.id and other.id != ^run.id and
              other.state in ^Run.active_states(),
          order_by: [asc: other.inserted_at]
      )

    case mode do
      "reject" when others != [] ->
        transition(run, "failed", principal,
          reason: "environment_busy",
          event_type: "policy_denied"
        )

      "cancel" ->
        for other <- others, other.state != "deploying" do
          transition(other, "cancelled", principal, reason: "superseded_by_newer_request")
        end

        {:ok, run}

      "supersede" ->
        for other <- others, other.state != "deploying" do
          transition(other, "superseded", principal,
            reason: "superseded_by_newer_request",
            superseded_by_run_id: run.id
          )
        end

        {:ok, run}

      _queue_or_idle ->
        {:ok, run}
    end
  end

  defp insert_request(repository, environment, principal, principal_type, attrs) do
    input_digest =
      digest([repository.id, environment.id, attrs["commit_sha"], attrs["artifact_digest"]])

    request_digest =
      digest([input_digest, attrs["source_ref"], attrs["source_workflow"] || ""])

    request = %Request{
      repository_id: repository.id,
      environment_id: environment.id,
      principal_type: principal_type,
      requested_by_user_id: principal.user && principal.user.id,
      requested_by_grant_id: principal.grant && principal.grant.id,
      request_digest: request_digest,
      input_digest: input_digest,
      requested_at: DateTime.utc_now()
    }

    case Repo.insert(Request.changeset(request, attrs)) do
      {:ok, inserted} ->
        {:ok, inserted}

      {:error, changeset} ->
        replay(repository, environment, attrs, request_digest, changeset)
    end
  end

  # An idempotency key is a promise about bytes. Replaying it with the same
  # request digest returns the original record; replaying it with anything else
  # is a conflict, because the caller believes it deployed something it did not.
  defp replay(repository, environment, attrs, request_digest, changeset) do
    existing =
      Repo.one(
        from request in Request,
          where:
            request.repository_id == ^repository.id and
              request.environment_id == ^environment.id and
              request.idempotency_key == ^to_string(attrs["idempotency_key"])
      )

    cond do
      is_nil(existing) -> {:error, changeset}
      existing.request_digest == request_digest -> {:ok, existing}
      true -> {:error, :idempotency_conflict}
    end
  end

  defp reevaluate_checking_runs(repository, %CheckResult{} = result, _principal) do
    runs =
      Repo.all(
        from run in Run,
          join: request in Request,
          on: request.id == run.deployment_request_id,
          where:
            run.repository_id == ^repository.id and run.state in ~w(requested checking) and
              request.commit_sha == ^result.commit_sha and
              request.artifact_digest == ^result.artifact_digest,
          preload: [:environment, :deployment_request]
      )

    for run <- runs do
      reevaluate(
        repository,
        run.environment,
        run.deployment_request,
        run,
        Principal.system("control_plane")
      )
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  defp append_event(%Run{} = run, type, principal, detail) do
    case insert_event(Repo, run, type, principal, detail, []) do
      {:ok, event} ->
        broadcast(run, event)
        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_event(repo, %Run{} = run, type, %Principal{} = principal, detail, states) do
    sequence =
      repo.one(
        from event in Event,
          where: event.deployment_run_id == ^run.id,
          select: coalesce(max(event.sequence), 0)
      ) + 1

    %Event{
      repository_id: run.repository_id,
      deployment_run_id: run.id,
      actor_type: Principal.actor_type(principal),
      actor_id: Principal.actor_id(principal)
    }
    |> Event.changeset(%{
      "sequence" => sequence,
      "type" => type,
      "from_state" => Keyword.get(states, :from),
      "to_state" => Keyword.get(states, :to),
      "detail" => scrub(detail)
    })
    |> repo.insert()
  end

  # Event detail reaches tenant reads and audit exports, so it is redacted and
  # bounded here rather than at each caller.
  defp scrub(detail) when is_map(detail) do
    detail
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), scrub_value(value)} end)
  end

  defp scrub_value(value) when is_binary(value),
    do: value |> OpenAgents.LogSafety.redact() |> String.slice(0, 500)

  defp scrub_value(value) when is_list(value), do: Enum.map(value, &scrub_value/1)
  defp scrub_value(value) when is_map(value), do: scrub(value)
  defp scrub_value(value), do: value

  defp broadcast(%Run{} = run, %Event{} = event) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      run_topic(run),
      {:deployment_event,
       %{run_id: run.id, sequence: event.sequence, type: event.type, state: run.state}}
    )
  end

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  defp release_expired(now, principal) do
    runs =
      Repo.all(
        from run in Run,
          where:
            run.state == "queued" and not is_nil(run.lease_expires_at) and
              run.lease_expires_at < ^now
      )

    for run <- runs do
      Repo.update_all(
        from(r in Run, where: r.id == ^run.id),
        set: [lease_owner: nil, lease_expires_at: nil, updated_at: DateTime.utc_now()]
      )

      append_event(run, "lease_released", principal, %{"reason" => "lease_expired"})
    end

    length(runs)
  end

  defp fail_uncertain(now, principal) do
    runs =
      Repo.all(
        from run in Run,
          where:
            run.state == "deploying" and not is_nil(run.lease_expires_at) and
              run.lease_expires_at < ^now
      )

    for run <- runs do
      transition(run, "failed", principal,
        reason: "provider_result_uncertain",
        event_type: "recovered",
        detail: %{"recovery" => "lease_expired_while_deploying"}
      )
    end

    length(runs)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp authorize_write(%Principal{kind: :user, user: %User{} = user}, %Repository{} = repository) do
    if OpenAgents.Repositories.writable?(repository, user) do
      :ok
    else
      {:error, {:forbidden, :not_writable}}
    end
  end

  defp authorize_write(%Principal{}, %Repository{}), do: {:error, {:forbidden, :not_writable}}

  defp fetch_environment_record(%Repository{} = repository, name) when is_binary(name) do
    case Repo.one(
           from environment in Environment,
             where: environment.repository_id == ^repository.id and environment.name == ^name
         ) do
      %Environment{} = environment -> {:ok, environment}
      nil -> {:error, :environment_not_found}
    end
  end

  defp fetch_environment_record(%Repository{}, _name), do: {:error, :environment_not_found}

  defp fetch_environment_by_id(%Repository{} = repository, id) do
    case Repo.get(Environment, id) do
      %Environment{} = environment ->
        with :ok <- Authority.check_repository(repository, environment), do: {:ok, environment}

      nil ->
        {:error, :environment_not_found}
    end
  end

  defp fetch_run_record(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Run, uuid) do
          %Run{} = run -> {:ok, run}
          nil -> {:error, :run_not_found}
        end

      :error ->
        {:error, :run_not_found}
    end
  end

  defp fetch_run_record(_id), do: {:error, :run_not_found}

  defp fetch_request_record(id) do
    case Repo.get(Request, id) do
      %Request{} = request -> {:ok, request}
      nil -> {:error, :request_not_found}
    end
  end

  defp check_results(%Repository{} = repository, commit_sha, artifact_digest) do
    Repo.all(
      from result in CheckResult,
        where:
          result.repository_id == ^repository.id and result.commit_sha == ^commit_sha and
            result.artifact_digest == ^artifact_digest
    )
  end

  defp store_explanation(%Run{} = run, explanation) do
    {_count, _runs} =
      Repo.update_all(
        from(r in Run, where: r.id == ^run.id),
        set: [policy_explanation: explanation, updated_at: DateTime.utc_now()]
      )

    %Run{run | policy_explanation: explanation}
  end

  defp claim(run_id, worker, expires_at, now) do
    Repo.update_all(
      from(run in Run,
        where: run.id == ^run_id and run.state == "queued",
        where: is_nil(run.lease_expires_at) or run.lease_expires_at < ^now,
        select: run
      ),
      set: [lease_owner: worker, lease_expires_at: expires_at, updated_at: now],
      inc: [attempt_count: 1]
    )
  end

  defp approvable(%Run{state: state}) when state in ~w(requested checking waiting_for_approval),
    do: :ok

  defp approvable(%Run{state: state}), do: {:error, {:illegal_transition, state, "queued"}}

  # An optimistic precondition: the caller states the state it believes the run
  # holds, and a mismatch is refused rather than applied to a run that moved.
  defp precondition(%Run{} = run, options) do
    case Keyword.get(options, :if_state) do
      nil -> :ok
      state when state == run.state -> :ok
      _mismatch -> {:error, :precondition_failed}
    end
  end

  defp cancel_requester(%Principal{user: %User{id: id}}), do: id
  defp cancel_requester(%Principal{}), do: nil

  defp intent(attrs) do
    %{
      source_ref: attrs["source_ref"],
      source_workflow: attrs["source_workflow"],
      workflow_run_id: attrs["workflow_run_id"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp put_creator(changeset, %Principal{user: %User{id: id}}, %Environment{id: nil}),
    do: Ecto.Changeset.put_change(changeset, :created_by_user_id, id)

  defp put_creator(changeset, _principal, _environment), do: changeset

  defp put_publisher(changeset, %Principal{kind: :workflow, grant: %WorkflowGrant{id: id}}),
    do: Ecto.Changeset.put_change(changeset, :published_by_grant_id, id)

  defp put_publisher(changeset, %Principal{user: %User{id: id}}),
    do: Ecto.Changeset.put_change(changeset, :published_by_user_id, id)

  defp put_publisher(changeset, %Principal{}), do: changeset

  defp verify_commit(%Repository{} = repository, commit_sha, commit_store)
       when is_function(commit_store, 2) do
    commit_store.(repository, to_string(commit_sha))
  end

  # Configurable so a host without git storage — and a test that does not need
  # one — can bind a different store, while the default reads real bytes.
  defp default_commit_store do
    Application.get_env(:openagents, :deployment_commit_store, &commit_exists/2)
  end

  # The commit must exist in the repository's own storage. Without this, a
  # request can name bytes the repository never received, and every downstream
  # check is then bound to nothing.
  defp commit_exists(%Repository{} = repository, commit_sha) do
    path = OpenAgents.Forge.Repos.bare_path(repository.storage_key)

    case OpenAgents.Forge.Repos.git(path, ["cat-file", "-e", commit_sha <> "^{commit}"]) do
      {_output, 0} -> :ok
      _missing -> {:error, :unknown_commit}
    end
  end

  defp grant_environment_id(_repository, nil), do: {:ok, nil}

  defp grant_environment_id(repository, name) do
    with {:ok, environment} <- fetch_environment_record(repository, name) do
      {:ok, environment.id}
    end
  end

  defp cursor_run(_repository, nil), do: nil

  defp cursor_run(%Repository{} = repository, cursor) do
    case fetch_run_record(cursor) do
      {:ok, %Run{repository_id: repository_id} = run} when repository_id == repository.id -> run
      _other -> nil
    end
  end

  # A grant's lifetime is clamped rather than trusted: a long-lived workflow
  # credential is the thing this design is trying not to have.
  defp grant_lifetime(seconds) when is_integer(seconds) and seconds > 0,
    do: min(seconds, WorkflowGrant.maximum_lifetime_seconds())

  defp grant_lifetime(_invalid), do: 900

  defp limit(options) do
    options
    |> Keyword.get(:limit, @default_limit)
    |> case do
      value when is_integer(value) and value > 0 -> min(value, @maximum_limit)
      _invalid -> @default_limit
    end
  end

  defp bounded_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.slice(0, 80)

  defp bounded_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 80)
  defp bounded_reason(_reason), do: "provider_failed"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp denil(:nil_value), do: nil
  defp denil(value), do: value

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp digest(parts) when is_list(parts) do
    parts
    |> Enum.map_join("\n", &to_string/1)
    |> digest()
  end

  defp digest(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc "The largest page any listing returns."
  @spec maximum_limit() :: pos_integer()
  def maximum_limit, do: @maximum_limit

  @doc "The page size a listing uses when the caller does not choose one."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit
end
