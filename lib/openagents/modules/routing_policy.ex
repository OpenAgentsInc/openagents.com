defmodule OpenAgents.Modules.RoutingPolicy do
  @moduledoc "Explicit host-owned constraints for deterministic module selection."

  alias OpenAgents.Provenance.Canonical

  @enforce_keys [
    :id,
    :version,
    :allowed_publishers,
    :allowed_costs,
    :allowed_qualities,
    :allowed_privacy,
    :allowed_residencies,
    :allowed_jurisdictions,
    :allowed_censorship_resistance,
    :allowed_approval_classes,
    :allowed_side_effects,
    :maximum_cost_units,
    :runtime_version,
    :digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec default() :: t()
  def default do
    fields = %{
      id: "sarah.routing.policy.default.v1",
      version: 1,
      allowed_publishers: ["OpenAgentsInc"],
      allowed_costs: ["included_first_party"],
      allowed_qualities: ["host_validated"],
      allowed_privacy: [
        "browser_conversation",
        "browser_scoped",
        "public_catalog_metadata_only",
        "signed_browser_owner"
      ],
      allowed_residencies: [
        "application_postgres",
        "application_process",
        "host",
        "operator_machine"
      ],
      allowed_jurisdictions: ["operator_unspecified"],
      allowed_censorship_resistance: ["not_claimed"],
      allowed_approval_classes: ["exact_current_user_consent", "host_policy"],
      allowed_side_effects: ["read_only", "reversible_write"],
      maximum_cost_units: 0,
      runtime_version: 1,
      digest: String.duplicate("0", 64)
    }

    policy = struct!(__MODULE__, fields)
    %{policy | digest: digest(policy)}
  end

  @doc """
  Policy for owners with an active paired machine: pairing approval on
  /computers is the operator's explicit approval, so machine-effect modules
  (`external_effect` with `explicit_operator_approval`) become routable.
  Execution still requires a matching approval receipt per module.
  """
  @spec paired_machine() :: t()
  def paired_machine do
    {:ok, policy} =
      new(%{
        id: "sarah.routing.policy.paired-machine.v1",
        allowed_approval_classes: [
          "exact_current_user_consent",
          "explicit_operator_approval",
          "host_policy"
        ],
        allowed_side_effects: ["external_effect", "read_only", "reversible_write"]
      })

    policy
  end

  @doc """
  Policy for an OpenAgents operator using capacity owned by OpenAgents.

  This policy admits the SCV module's external effect and residency into the
  routing stage. Execution still requires the module-specific operator receipt,
  and `OpenAgents.SCV.Deployments` independently verifies the operator again
  before it spends capacity.
  """
  @spec operator() :: t()
  def operator do
    {:ok, policy} =
      new(%{
        id: "sarah.routing.policy.operator.v1",
        allowed_residencies: [
          "application_postgres",
          "application_process",
          "host",
          "openagents_capacity",
          "operator_machine"
        ],
        allowed_approval_classes: [
          "exact_current_user_consent",
          "explicit_operator_approval",
          "host_policy"
        ],
        allowed_side_effects: ["external_effect", "read_only", "reversible_write"]
      })

    policy
  end

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attributes) when is_map(attributes) do
    base = default()

    fields =
      base
      |> Map.from_struct()
      |> Map.merge(attributes)
      |> Map.put(:digest, String.duplicate("0", 64))

    try do
      policy = struct!(__MODULE__, fields)
      policy = %{policy | digest: digest(policy)}

      case validate(policy) do
        :ok -> {:ok, policy}
        {:error, reason} -> {:error, reason}
      end
    rescue
      _exception -> {:error, :routing_policy_invalid}
    end
  end

  def new(_attributes), do: {:error, :routing_policy_invalid}

  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = policy) do
    list_fields = [
      policy.allowed_publishers,
      policy.allowed_costs,
      policy.allowed_qualities,
      policy.allowed_privacy,
      policy.allowed_residencies,
      policy.allowed_jurisdictions,
      policy.allowed_censorship_resistance,
      policy.allowed_approval_classes,
      policy.allowed_side_effects
    ]

    cond do
      not bounded?(policy.id, 128) or not is_integer(policy.version) or policy.version < 1 ->
        {:error, :routing_policy_identity_invalid}

      not is_integer(policy.runtime_version) or policy.runtime_version < 1 ->
        {:error, :routing_policy_runtime_invalid}

      not is_integer(policy.maximum_cost_units) or policy.maximum_cost_units < 0 ->
        {:error, :routing_policy_budget_invalid}

      not Enum.all?(list_fields, &bounded_list?/1) ->
        {:error, :routing_policy_constraints_invalid}

      policy.digest != digest(policy) ->
        {:error, :routing_policy_digest_invalid}

      true ->
        :ok
    end
  end

  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = policy) do
    policy
    |> Map.from_struct()
    |> Map.delete(:digest)
    |> Canonical.digest!()
  end

  defp bounded_list?(values) when is_list(values) and values != [] and length(values) <= 32,
    do: values == Enum.sort(Enum.uniq(values)) and Enum.all?(values, &bounded?(&1, 128))

  defp bounded_list?(_values), do: false
  defp bounded?(value, maximum), do: is_binary(value) and byte_size(value) in 1..maximum
end
