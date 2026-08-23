defmodule OpenAgents.Deployments.Provider do
  @moduledoc """
  The contract every deployment provider implements.

  A provider receives an `OpenAgents.Deployments.Execution` and nothing else. It
  never receives the caller's credential, the caller's membership, or the request
  parameters, because a provider is the least trusted part of this system: it
  talks to the outside world.

  Three results exist, and the third is the point:

    * `{:ok, receipt}` — the deployment is live, and the receipt is bounded,
      sanitized metadata the tenant may read.
    * `{:error, reason}` — the deployment definitively did not happen.
    * `{:uncertain, detail}` — the provider does not know. A timeout, a lost
      connection, or a partial rollout returns this. The control plane records an
      explicitly uncertain failure rather than guessing, because a success
      receipt for an unknown outcome is worse than no receipt.

  `cancel/1` is best-effort and bounded: it asks the provider to stop, and the
  run still reaches its terminal state through the normal lifecycle rather than
  by the canceller's assertion.

  Providers must be idempotent by `run_id`. The worker may call `deploy/1` again
  after a crash, and calling it twice for one run must not deploy twice.
  """

  alias OpenAgents.Deployments.Execution

  @type receipt :: %{optional(String.t()) => term()}
  @type result :: {:ok, receipt()} | {:error, atom()} | {:uncertain, receipt()}

  @doc "Deploy the admitted execution. Must be idempotent by `execution.run_id`."
  @callback deploy(Execution.t()) :: result()

  @doc "Ask the provider to stop an in-flight execution. Best-effort."
  @callback cancel(Execution.t()) :: :ok | {:error, atom()}

  @doc "The secret references this provider requires from the environment."
  @callback required_secret_references(map()) :: [String.t()]

  @maximum_receipt_keys 20
  @maximum_receipt_value_bytes 500

  @doc """
  Resolve a provider name to its module.

  Only configured providers resolve. A tenant naming an arbitrary module would
  otherwise choose which code the control plane runs.
  """
  @spec fetch(String.t()) :: {:ok, module()} | {:error, :unknown_provider}
  def fetch(name) when is_binary(name) do
    case Map.fetch(configured(), name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_provider}
    end
  end

  @doc "The configured provider names."
  @spec names() :: [String.t()]
  def names, do: configured() |> Map.keys() |> Enum.sort()

  @doc """
  Sanitize a provider receipt before it is stored or read back.

  Providers are bounded here rather than trusted: a receipt is flattened to
  scalars, truncated, key-limited, and credential-redacted, so provider output
  cannot smuggle a secret into a durable record or an event stream.
  """
  @spec sanitize_receipt(term(), [String.t()]) :: receipt()
  def sanitize_receipt(receipt, secret_values \\ [])

  def sanitize_receipt(receipt, secret_values) when is_map(receipt) do
    receipt
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(@maximum_receipt_keys)
    |> Map.new(fn {key, value} -> {sanitize_key(key), sanitize_value(value, secret_values)} end)
  end

  def sanitize_receipt(_receipt, _secret_values), do: %{}

  defp configured do
    Application.get_env(:openagents, :deployment_providers, %{
      "fake" => OpenAgents.Deployments.Providers.Fake
    })
  end

  defp sanitize_key(key) do
    key
    |> to_string()
    |> String.slice(0, 60)
  end

  defp sanitize_value(value, secret_values) when is_binary(value) do
    value
    |> mask_secret_values(secret_values)
    |> OpenAgents.LogSafety.redact()
    |> String.slice(0, @maximum_receipt_value_bytes)
  end

  defp sanitize_value(value, _secrets) when is_integer(value) or is_boolean(value), do: value
  defp sanitize_value(%DateTime{} = value, _secrets), do: DateTime.to_iso8601(value)
  defp sanitize_value(value, _secrets) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(_value, _secrets), do: nil

  # A provider that echoes a credential it was handed is a leak the control
  # plane can close, so resolved values are masked by exact match before the
  # generic credential patterns run.
  defp mask_secret_values(value, secret_values) do
    secret_values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4))
    |> Enum.reduce(value, &String.replace(&2, &1, "[REDACTED_SECRET]"))
  end
end
