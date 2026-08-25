defmodule OpenAgents.Repo.Migrations.DropMachinePairingUserId do
  use Ecto.Migration

  @moduledoc """
  `machine_pairings.user_id` is no longer written or read, and the drop is
  deferred to the release after the one that stops writing it.

  This is the expand half of expand-and-contract, and the reason is the roll
  rather than the column. A rolling replacement runs migrations on the first
  node while the other two still serve the previous release, and that release
  declares `belongs_to :user` on `OpenAgents.Machines.Pairing` — which puts
  `user_id` into every generated `SELECT`. Dropping the column here would make
  every read and write of `machine_pairings` fail on the un-replaced nodes, so
  CLI device pairing would break for two thirds of traffic, then one third,
  for the length of the roll.

  The column is dead weight and nothing else: the current release neither
  writes nor reads it, and the owner it named is reachable through
  `machines.user_id` (issue #184, CANON-002). Carrying it for one release
  costs a nullable column; dropping it during a roll costs pairing.

  The contract half — the actual `remove` — belongs in a later migration, once
  the release that stopped writing it is live on every node.
  """

  def up do
    :ok
  end

  def down do
    :ok
  end
end
