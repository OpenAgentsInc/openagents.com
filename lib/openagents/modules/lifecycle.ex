defmodule OpenAgents.Modules.Lifecycle do
  @moduledoc "Authenticated operator lifecycle authority applied only to later turn captures."

  import Ecto.Query

  alias OpenAgents.Modules.{Artifact, LifecycleReceipt}
  alias OpenAgents.Repo
  alias OpenAgents.Tools.{Registry, Snapshot}

  @transitions %{
    "stage" => ~w(admitted deprecated disabled),
    "admit" => ~w(staged disabled deprecated),
    "deprecate" => ~w(admitted),
    "disable" => ~w(staged admitted deprecated),
    "revoke" => ~w(staged admitted deprecated disabled),
    "rollback" => ~w(admitted deprecated)
  }

  @spec capture(Snapshot.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def capture(%Snapshot{} = base_snapshot) do
    latest_receipts()
    |> Enum.reduce_while({:ok, base_snapshot}, fn receipt, {:ok, snapshot} ->
      case apply_receipt(snapshot, base_snapshot, receipt) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec transition(Snapshot.t(), String.t(), pos_integer(), String.t(), map(), map()) ::
          {:ok, LifecycleReceipt.t(), Snapshot.t()} | {:error, term()}
  def transition(%Snapshot{} = base_snapshot, module_id, version, action, operator, attributes)
      when is_binary(module_id) and is_integer(version) and is_binary(action) and
             is_map(operator) and is_map(attributes) do
    with :ok <- validate_operator(operator),
         true <- Map.has_key?(@transitions, action) || {:error, :module_action_invalid},
         {:ok, current_snapshot} <- capture(base_snapshot),
         {:ok, current_artifact} <- fetch_any(current_snapshot, module_id, version),
         :ok <- Artifact.validate(current_artifact),
         current_state <- lifecycle_state(current_artifact.state),
         :ok <- validate_transition(action, current_state),
         {:ok, dependent_refs} <- impact_check(current_snapshot, current_artifact, action),
         {:ok, target_state, options} <- transition_options(action, current_artifact, attributes),
         {:ok, resulting_snapshot} <-
           Registry.transition_module(
             current_snapshot,
             module_id,
             version,
             target_state,
             options
           ),
         {:ok, resulting_artifact} <- fetch_any(resulting_snapshot, module_id, version),
         {:ok, receipt} <-
           persist_receipt(
             base_snapshot,
             current_artifact,
             resulting_artifact,
             resulting_snapshot,
             action,
             current_state,
             target_lifecycle_state(action, target_state),
             operator,
             attributes,
             dependent_refs,
             options
           ) do
      {:ok, receipt, resulting_snapshot}
    else
      false -> {:error, :module_action_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  def transition(%Snapshot{}, _module_id, _version, _action, _operator, _attributes),
    do: {:error, :module_lifecycle_request_invalid}

  defp latest_receipts do
    Repo.all(
      from(receipt in LifecycleReceipt,
        order_by: [asc: receipt.module_id, asc: receipt.module_version, desc: receipt.generation]
      )
    )
    |> Enum.uniq_by(&{&1.module_id, &1.module_version})
    |> Enum.sort_by(&{&1.module_id, &1.module_version})
  end

  defp apply_receipt(snapshot, base_snapshot, receipt) do
    with {:ok, base_artifact} <-
           fetch_any(base_snapshot, receipt.module_id, receipt.module_version),
         true <-
           base_artifact.artifact_digest == receipt.base_artifact_digest ||
             {:error, :module_lifecycle_base_changed},
         {:ok, updated} <-
           Registry.transition_module(
             snapshot,
             receipt.module_id,
             receipt.module_version,
             artifact_state(receipt.to_state),
             predecessor: receipt.predecessor,
             deprecation: receipt.deprecation
           ),
         {:ok, artifact} <- fetch_any(updated, receipt.module_id, receipt.module_version),
         true <-
           artifact.artifact_digest == receipt.resulting_artifact_digest ||
             {:error, :module_lifecycle_receipt_mismatch} do
      {:ok, updated}
    else
      false -> {:error, :module_lifecycle_receipt_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_receipt(
         base_snapshot,
         current_artifact,
         resulting_artifact,
         resulting_snapshot,
         action,
         from_state,
         to_state,
         operator,
         attributes,
         dependent_refs,
         options
       ) do
    Repo.transaction(fn ->
      advisory_lock!(current_artifact.module_id, current_artifact.version)

      generation =
        Repo.one(
          from(receipt in LifecycleReceipt,
            where:
              receipt.module_id == ^current_artifact.module_id and
                receipt.module_version == ^current_artifact.version,
            select: max(receipt.generation)
          )
        ) || 0

      base_artifact =
        Map.fetch!(base_snapshot.modules, {current_artifact.module_id, current_artifact.version})

      attributes = %{
        module_id: current_artifact.module_id,
        module_version: current_artifact.version,
        generation: generation + 1,
        action: action,
        from_state: from_state,
        to_state: to_state,
        base_artifact_digest: base_artifact.artifact_digest,
        resulting_artifact_digest: resulting_artifact.artifact_digest,
        base_registry_digest: base_snapshot.digest,
        resulting_registry_digest: resulting_snapshot.digest,
        actor_id: operator.actor_id,
        auth_method: operator.auth_method,
        approval_receipt_ref: operator.approval_receipt_ref,
        reason: Map.get(attributes, "reason"),
        predecessor: Keyword.get(options, :predecessor),
        deprecation: Keyword.get(options, :deprecation),
        dependent_refs: dependent_refs
      }

      case Repo.insert(LifecycleReceipt.create_changeset(%LifecycleReceipt{}, attributes)) do
        {:ok, receipt} -> receipt
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp advisory_lock!(module_id, version) do
    key = module_id <> ":" <> Integer.to_string(version)
    _result = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  defp transition_options(action, artifact, attributes) do
    reason = Map.get(attributes, "reason")

    if is_binary(reason) and byte_size(reason) in 1..1_000 do
      predecessor = reference(artifact)

      case action do
        "deprecate" ->
          replacement = Map.get(attributes, "replacement")

          if is_nil(replacement) or valid_reference?(replacement) do
            {:ok, "deprecated",
             predecessor: predecessor,
             deprecation: %{"reason" => reason, "replacement" => replacement}}
          else
            {:error, :module_replacement_invalid}
          end

        "stage" ->
          {:ok, "disabled", predecessor: predecessor, deprecation: nil}

        "admit" ->
          {:ok, "admitted", predecessor: predecessor, deprecation: nil}

        "disable" ->
          {:ok, "disabled", predecessor: predecessor, deprecation: nil}

        "revoke" ->
          {:ok, "revoked", predecessor: predecessor, deprecation: nil}

        "rollback" ->
          rollback_options(artifact, attributes)
      end
    else
      {:error, :module_lifecycle_reason_invalid}
    end
  end

  defp rollback_options(artifact, %{"predecessor" => predecessor}) do
    if valid_reference?(predecessor) and artifact.predecessor == predecessor,
      do: {:ok, "admitted", predecessor: predecessor, deprecation: nil},
      else: {:error, :module_rollback_predecessor_mismatch}
  end

  defp rollback_options(_artifact, _attributes),
    do: {:error, :module_rollback_predecessor_missing}

  defp impact_check(snapshot, artifact, action) when action in ~w(disable revoke) do
    dependents =
      snapshot.modules
      |> Map.values()
      |> Enum.filter(&Artifact.executable?/1)
      |> Enum.filter(fn candidate ->
        Enum.any?(candidate.compatibility["dependencies"], fn dependency ->
          dependency["module_id"] == artifact.module_id and
            dependency["version"] == artifact.version
        end)
      end)
      |> Enum.map(&"module:#{&1.module_id}:#{&1.version}:#{&1.artifact_digest}")

    if dependents == [], do: {:ok, []}, else: {:error, {:active_module_dependents, dependents}}
  end

  defp impact_check(_snapshot, _artifact, _action), do: {:ok, []}

  defp validate_operator(%{
         authenticated: true,
         role: "operator",
         actor_id: actor_id,
         auth_method: auth_method,
         approval_receipt_ref: approval_receipt_ref
       }) do
    if Enum.all?([actor_id, auth_method, approval_receipt_ref], fn value ->
         is_binary(value) and byte_size(value) in 1..256
       end),
       do: :ok,
       else: {:error, :operator_identity_invalid}
  end

  defp validate_operator(_operator), do: {:error, :authenticated_operator_required}

  defp validate_transition(action, state) do
    if state in Map.fetch!(@transitions, action),
      do: :ok,
      else: {:error, {:module_transition_invalid, state, action}}
  end

  defp fetch_any(snapshot, module_id, version) do
    case Map.fetch(snapshot.modules, {module_id, version}) do
      {:ok, artifact} -> {:ok, artifact}
      :error -> {:error, :unknown_module}
    end
  end

  defp lifecycle_state("admitted"), do: "admitted"
  defp lifecycle_state("deprecated"), do: "deprecated"
  defp lifecycle_state("disabled"), do: "disabled"
  defp lifecycle_state("revoked"), do: "revoked"

  defp artifact_state("staged"), do: "disabled"
  defp artifact_state(state), do: state
  defp target_lifecycle_state("stage", _state), do: "staged"
  defp target_lifecycle_state(_action, state), do: state

  defp reference(artifact),
    do: %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest
    }

  defp valid_reference?(%{
         "module_id" => module_id,
         "version" => version,
         "artifact_digest" => digest
       }),
       do:
         is_binary(module_id) and is_integer(version) and version > 0 and is_binary(digest) and
           Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_reference?(_reference), do: false
end
