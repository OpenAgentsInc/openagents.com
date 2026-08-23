defmodule OpenAgents.Forge.Promotion do
  @moduledoc """
  The one authority path for promoting a pushed commit as the fleet target.

  Promotion is release authority over the OpenAgents fleet itself, so it is
  not part of the tenant deployment control plane (`OpenAgents.Deployments`)
  and no tenant credential reaches it. Two callers exist and both come through
  here: the `/admin/forge` **Promote** button and
  `OpenAgentsWeb.FleetTargetController`. Neither one restates the policy, so
  the browser and the API cannot drift apart.

  What this module decides, once, for both:

  - The promoting account is an operator *at this moment*. Removing an account
    from the allowlist stops its next promotion, credential or not.
  - The environment is named exactly, and only `production` exists today.
  - The commit is named exactly. `OpenAgents.Forge.Targets.promote/4` still
    owns the WAL-backed existence check, the 40-character SHA format, and the
    deployable-repository check, so a push can never promote itself.
  - A caller-generated idempotency key names one promotion. Replaying it with
    the same bytes returns the original target; replaying it with different
    bytes is a conflict.
  - An optional expected-current-target ID is a compare-and-set precondition,
    so two concurrent operators cannot unknowingly supersede each other.

  The receipt is the append-only `forge_fleet_targets` row that
  `OpenAgents.Forge.Targets.promote/4` writes, carrying the promoting
  operator's identity in `promoted_by` exactly as the browser path always
  has. The bounded audit event beside it records the principal, the source
  channel, and a digest of the idempotency key — never the key itself.
  """

  import Ecto.Query

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Audit
  alias OpenAgents.Forge.{Target, Targets}
  alias OpenAgents.Repo

  @environments ["production"]
  @sources ["operator_console", "api"]

  @type source :: String.t()
  @type result :: %{target: Target.t(), replayed: boolean()}

  @doc "Environments this surface admits. Fleet promotion has exactly one."
  @spec environments() :: [String.t()]
  def environments, do: @environments

  @doc "The immutable principal string recorded on a promotion receipt."
  @spec principal(User.t()) :: String.t()
  def principal(%User{github_id: github_id}), do: "operator:" <> to_string(github_id)

  @doc """
  Promote `attrs["sha"]` as the fleet target for `attrs["repo"]`.

  Returns `{:ok, %{target: target, replayed: replayed?}}`, where `replayed?`
  is true when an identical idempotency key already named this promotion.
  """
  @spec promote(User.t() | nil, map()) :: {:ok, result()} | {:error, term()}
  def promote(user, attrs) when is_map(attrs) do
    with {:ok, operator} <- operator(user, attrs),
         {:ok, request} <- request(attrs) do
      serialized(request.repo, fn -> admit(operator, request) end)
    end
  end

  defp operator(%User{} = user, attrs) do
    if Accounts.admin?(user) do
      {:ok, user}
    else
      refuse(user, attrs, :not_operator)
    end
  end

  defp operator(_user, _attrs), do: {:error, :not_operator}

  # Every promotion for one repository is decided under one cluster-wide lock,
  # so the idempotency lookup, the precondition, and the insert are one
  # decision rather than three racing reads.
  defp serialized(repo, work) do
    :global.trans({{:forge_target_promote, repo}, self()}, work)
  end

  defp admit(operator, request) do
    with {:ok, :new} <- replay(request),
         :ok <- precondition(request) do
      insert(operator, request)
    else
      {:ok, {:replayed, target}} -> {:ok, %{target: target, replayed: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert(operator, request) do
    case Targets.promote(request.repo, request.sha, principal(operator),
           details: details(operator, request)
         ) do
      {:ok, target} ->
        record(operator, request, target)
        {:ok, %{target: target, replayed: false}}

      {:error, reason} ->
        record_refusal(operator, request, reason)
        {:error, reason}
    end
  end

  defp details(operator, request) do
    %{
      "promoted_by_user_id" => operator.id,
      "promotion_environment" => request.environment,
      "promotion_request_digest" => request.request_digest,
      "promotion_source" => request.source
    }
    |> maybe_put("idempotency_key_digest", request.idempotency_key_digest)
    |> maybe_put("promotion_request_id", request.request_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A key names one promotion. The same key with the same bytes is the same
  # promotion; the same key with different bytes is a caller bug, and
  # answering it with the original target would hide a wrong deployment.
  defp replay(%{idempotency_key_digest: nil}), do: {:ok, :new}

  defp replay(request) do
    Target
    |> where([target], target.repo == ^request.repo)
    |> where(
      [target],
      fragment("?->>'idempotency_key_digest'", target.details) ==
        ^request.idempotency_key_digest
    )
    |> order_by([target], desc: target.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        {:ok, :new}

      %Target{details: %{"promotion_request_digest" => digest}} = target
      when digest == request.request_digest ->
        {:ok, {:replayed, target}}

      %Target{} ->
        {:error, :idempotency_conflict}
    end
  end

  defp precondition(%{expected_current_target_id: nil}), do: :ok

  defp precondition(request) do
    case Targets.current(request.repo) do
      %Target{id: id} when id == request.expected_current_target_id -> :ok
      _superseded -> {:error, :precondition_failed}
    end
  end

  defp request(attrs) do
    with {:ok, repo} <- bounded(attrs, "repo", :invalid_repository),
         {:ok, sha} <- bounded(attrs, "sha", :invalid_sha),
         {:ok, source} <- source(attrs),
         {:ok, environment} <- environment(attrs),
         {:ok, key} <- idempotency_key(attrs, source),
         {:ok, expected} <- expected_current_target_id(attrs) do
      {:ok,
       %{
         environment: environment,
         expected_current_target_id: expected,
         idempotency_key_digest: key && digest(key),
         repo: repo,
         request_digest: digest(Enum.join([repo, sha, environment], "\n")),
         request_id: request_id(attrs),
         sha: sha,
         source: source
       }}
    end
  end

  defp bounded(attrs, key, reason) do
    case value(attrs, key) do
      binary when is_binary(binary) and byte_size(binary) in 1..255 -> {:ok, binary}
      _invalid -> {:error, reason}
    end
  end

  defp source(attrs) do
    case value(attrs, "source") do
      source when source in @sources -> {:ok, source}
      nil -> {:ok, "api"}
      _invalid -> {:error, :invalid_source}
    end
  end

  defp environment(attrs) do
    case value(attrs, "environment") do
      environment when environment in @environments -> {:ok, environment}
      _invalid -> {:error, :unsupported_environment}
    end
  end

  # The browser button is one operator's one click, so it needs no key. Every
  # other caller is a script that can retry, and a retry without a key is how
  # a fleet gets promoted twice.
  defp idempotency_key(_attrs, "operator_console"), do: {:ok, nil}

  defp idempotency_key(attrs, _source) do
    case value(attrs, "idempotency_key") do
      key when is_binary(key) and byte_size(key) in 8..255 -> {:ok, key}
      _invalid -> {:error, :invalid_idempotency_key}
    end
  end

  defp expected_current_target_id(attrs) do
    case value(attrs, "expected_current_target_id") do
      nil -> {:ok, nil}
      id when is_binary(id) -> cast_uuid(id)
      _invalid -> {:error, :invalid_expected_target}
    end
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_expected_target}
    end
  end

  defp request_id(attrs) do
    case value(attrs, "request_id") do
      id when is_binary(id) and byte_size(id) in 1..128 -> id
      _absent -> nil
    end
  end

  defp value(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, String.to_existing_atom(key))) do
      "" -> nil
      other -> other
    end
  rescue
    ArgumentError -> Map.get(attrs, key)
  end

  defp record(operator, request, target) do
    Audit.record!(
      "forge.fleet_target.promoted",
      {:operator, operator.id},
      "forge_fleet_target",
      target.id,
      metadata: audit_metadata(request, %{"result" => "promoted", "sha" => target.sha})
    )
  end

  defp record_refusal(operator, request, reason) do
    Audit.record!(
      "forge.fleet_target.promotion_refused",
      {:operator, operator.id},
      "forge_repository",
      request.repo,
      metadata: audit_metadata(request, %{"result" => "refused", "reason" => reason_code(reason)})
    )
  end

  defp refuse(user, attrs, reason) do
    Audit.record!(
      "forge.fleet_target.promotion_refused",
      {:user, user && user.id},
      "forge_repository",
      to_string(Map.get(attrs, "repo") || Map.get(attrs, :repo) || "unknown"),
      metadata: %{"reason" => Atom.to_string(reason), "result" => "refused"}
    )

    {:error, reason}
  end

  defp audit_metadata(request, extra) do
    %{
      "environment" => request.environment,
      "repo" => request.repo,
      "request_digest" => request.request_digest,
      "source" => request.source
    }
    |> maybe_put("idempotency_key_digest", request.idempotency_key_digest)
    |> maybe_put("request_id", request.request_id)
    |> Map.merge(extra)
  end

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "invalid"

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
