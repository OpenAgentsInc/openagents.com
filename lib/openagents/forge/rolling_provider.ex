defmodule OpenAgents.Forge.RollingProvider do
  @moduledoc """
  Infrastructure boundary for one-node-at-a-time replacement.

  Gate 12 must supply an isolated staging implementation. Provider callbacks
  receive only bounded deployment context; credentials and private host data
  remain in operator-owned configuration.
  """

  @type context :: %{
          required(:sha) => binary(),
          required(:previous_sha) => binary(),
          required(:image_digest) => binary(),
          required(:previous_image_digest) => binary(),
          required(:expected_nodes) => [node()]
        }

  @callback remove_readiness(node(), context()) :: :ok | {:error, term()}
  @callback members() :: [node()]
  @callback restore_readiness(node(), context()) :: :ok | {:error, term()}
  @callback drain(node(), context()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback capacity([node()], context()) ::
              {:ok, %{required(:ready) => non_neg_integer(), required(:quorum) => boolean()}}
              | {:error, term()}
  @callback replace(node(), binary(), context()) :: :ok | {:error, term()}
  @callback status(node(), context()) ::
              {:ok,
               %{
                 required(:member) => boolean(),
                 required(:ready) => boolean(),
                 required(:boot_converged) => boolean(),
                 required(:database_ready) => boolean(),
                 required(:sha) => binary(),
                 required(:image_digest) => binary()
               }}
              | {:error, term()}
  @callback rollback(node(), binary(), context()) :: :ok | {:error, term()}
end
