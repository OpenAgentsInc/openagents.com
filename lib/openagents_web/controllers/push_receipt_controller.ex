defmodule OpenAgentsWeb.PushReceiptController do
  @moduledoc """
  The push receipts of one repository, read from the WAL.

  A push is acknowledged only after the WAL accepts it, and every accepted
  entry carries the `EXIT-005` chain link binding it to the entry before it.
  `OpenAgents.Forge.Pushes` returns that link to the pusher in the
  `git receive-pack` side band, and this route serves the same values
  afterwards for a pusher who did not keep their terminal output.

  What re-fetching does and does not settle is worth stating, because a
  receipt that is misread is worse than none. The evidence is the link the
  pusher *retained*, not the link this route returns: an operator who rewrote
  the log would serve the rewritten link here too. Comparing a retained link
  against `OpenAgents.Forge.Verification.verify/2` is the check;
  `docs/2026-08-23-forge-wal-anchoring.md` sets out the limits.

  The receipts come from the WAL rather than the derived `forge_pushes` rows,
  so the record this publishes is the record the verifier reads. Entries
  written before the chain existed carry no link, and `chained_from` names the
  first sequence that does. A `null` link before that sequence is history; the
  chain stopping after it is not.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Forge.WAL
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiError
  alias OpenAgentsWeb.ControllerHelpers

  @default_limit 30
  @max_limit 100

  def index(conn, %{"owner" => owner, "repo" => repo} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    case receipts(repository) do
      {:ok, receipts, chained_from} ->
        limit = limit(params["per_page"])

        json(conn, %{
          "repo" => "#{repository.owner}/#{repository.name}",
          "chained_from" => chained_from,
          "pushes" => receipts |> Enum.reverse() |> Enum.take(limit)
        })

      {:error, _reason} ->
        ApiError.refuse(conn, "push_record_unreadable")
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "wal_seq" => wal_seq}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    seq = ControllerHelpers.integer_param!(wal_seq)

    case receipts(repository) do
      {:ok, receipts, _chained_from} ->
        case Enum.find(receipts, &(&1["wal_seq"] == seq)) do
          %{} = receipt -> json(conn, receipt)
          nil -> ApiError.not_found(conn)
        end

      {:error, _reason} ->
        ApiError.refuse(conn, "push_record_unreadable")
    end
  rescue
    Ecto.NoResultsError -> ApiError.not_found(conn)
  end

  # Oldest first, so each entry's ref changes are read against the post-state
  # the entry before it recorded — the same derivation
  # `OpenAgents.Forge.Pushes.reconcile_receipts/1` uses.
  defp receipts(repository) do
    case WAL.read_index(repository.storage_key) do
      # A repository nobody has pushed to has no index and no receipts. That
      # is an empty record, not an unreadable one, and saying so is the whole
      # difference between "no push was recorded" and "the record is missing".
      {:error, :not_found} ->
        {:ok, [], nil}

      {:ok, _generation, index} ->
        entries = WAL.entries(index)

        receipts =
          entries
          |> Enum.map_reduce(%{}, fn entry, refs_before ->
            {receipt(entry, refs_before), entry["refs"] || %{}}
          end)
          |> elem(0)

        {:ok, receipts, chained_from(entries)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chained_from(entries) do
    case Enum.find(entries, &(WAL.entry_link(&1) != nil)) do
      nil -> nil
      entry -> entry["seq"]
    end
  end

  defp receipt(entry, refs_before) do
    refs_after = entry["refs"] || %{}

    changed =
      refs_after
      |> Enum.filter(fn {name, sha} -> refs_before[name] != sha end)
      |> Map.new(fn {name, sha} -> {name, %{"old" => refs_before[name], "new" => sha}} end)

    deleted =
      refs_before
      |> Enum.reject(fn {name, _sha} -> Map.has_key?(refs_after, name) end)
      |> Map.new(fn {name, sha} -> {name, %{"old" => sha, "new" => nil}} end)

    %{
      "wal_seq" => entry["seq"],
      "link" => WAL.entry_link(entry),
      "format" => entry["format"],
      "principal" => entry["principal"],
      "pushed_at" => entry["pushed_at"],
      "refs" => Map.merge(changed, deleted)
    }
  end

  defp limit(nil), do: @default_limit

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> min(parsed, @max_limit)
      _unusable -> @default_limit
    end
  end

  defp limit(_value), do: @default_limit
end
