defmodule OpenAgents.Memory.Portability do
  @moduledoc "Optional explicit encrypted export/import behind Sarah's browser-local memory contracts."

  import Ecto.Query

  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Memory.Portability.{Envelope, ExportReceipt, ImportItem, ImportReceipt}
  alias OpenAgents.ProfileMemory
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @payload_schema "sarah.portable_memory_payload.v1"
  @maximum_records 200

  def export_bundle(%Visitor{} = owner, passphrase) do
    with :ok <- enabled() do
      transaction(fn ->
        advisory_lock!("export", owner.id)
        {:ok, profile} = ProfileMemory.export(owner)
        records = Enum.take(profile["records"], @maximum_records)
        previous = latest_export(owner.id)
        sequence = if(previous, do: previous.sequence + 1, else: 1)
        installation_ref = installation_ref(owner.id)

        payload = %{
          "schema" => @payload_schema,
          "source_installation_ref" => installation_ref,
          "export_sequence" => sequence,
          "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "profile" => %{
            "schema" => profile["schema"],
            "records" => records,
            "truncated" => profile["truncated"]
          }
        }

        case Envelope.seal(payload, passphrase) do
          {:ok, envelope} ->
            now = DateTime.utc_now()

            if previous && previous.status == "active" do
              update!(
                ExportReceipt.transition_changeset(previous, %{status: "rotated", rotated_at: now})
              )
            end

            receipt =
              insert!(
                ExportReceipt.create_changeset(%ExportReceipt{}, %{
                  owner_visitor_id: owner.id,
                  source_installation_ref: installation_ref,
                  sequence: sequence,
                  envelope_digest: Envelope.digest(envelope),
                  profile_record_count: length(records),
                  kdf_id: Envelope.kdf_id(),
                  cipher_id: Envelope.cipher_id(),
                  status: "active",
                  previous_export_id: if(previous, do: previous.id)
                })
              )

            %{envelope: envelope, receipt: receipt}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  def import_bundle(%Visitor{} = owner, envelope, passphrase, confirmation) do
    with :ok <- enabled(),
         :ok <- import_confirmation(confirmation),
         {:ok, payload} <- Envelope.open(envelope, passphrase),
         {:ok, prepared} <- validate_payload(payload) do
      transaction(fn ->
        advisory_lock!("import", owner.id <> ":" <> prepared.installation_ref)
        envelope_digest = Envelope.digest(envelope)
        prevent_replay!(owner.id, prepared.installation_ref, prepared.sequence, envelope_digest)

        results =
          Enum.map(prepared.records, fn record ->
            import_record(owner, prepared.installation_ref, record)
          end)

        counts = Enum.frequencies_by(results, & &1.disposition)
        confirmation_digest = Canonical.digest!(confirmation)

        receipt =
          insert!(
            ImportReceipt.create_changeset(%ImportReceipt{}, %{
              owner_visitor_id: owner.id,
              source_installation_ref: prepared.installation_ref,
              export_sequence: prepared.sequence,
              envelope_digest: envelope_digest,
              confirmation_digest: confirmation_digest,
              status: "active",
              imported_count: Map.get(counts, "imported", 0),
              unchanged_count: Map.get(counts, "unchanged", 0),
              conflict_count: Map.get(counts, "conflict", 0),
              tombstone_count:
                Map.get(counts, "tombstone_applied", 0) +
                  Map.get(counts, "tombstone_absent", 0)
            })
          )

        Enum.each(results, fn result ->
          insert!(
            ImportItem.changeset(%ImportItem{}, %{
              import_receipt_id: receipt.id,
              origin_record_ref: result.origin_record_ref,
              destination_record_id: result.destination_record_id,
              source_status: result.source_status,
              disposition: result.disposition
            })
          )
        end)

        %{receipt: receipt, items: results}
      end)
    end
  end

  def revoke_import(%Visitor{} = owner, receipt_id, confirmation) do
    with :ok <- enabled(),
         :ok <- revocation_confirmation(confirmation) do
      transaction(fn ->
        receipt =
          Repo.one(
            from(r in ImportReceipt,
              where: r.id == ^receipt_id and r.owner_visitor_id == ^owner.id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:import_receipt_not_found)

        if receipt.status != "active", do: Repo.rollback(:import_already_revoked)

        items =
          Repo.all(
            from(i in ImportItem,
              where: i.import_receipt_id == ^receipt.id and not is_nil(i.destination_record_id)
            )
          )

        Enum.each(items, &forget_destination(owner, &1.destination_record_id))
        now = DateTime.utc_now()

        projection = %{
          "receipt_id" => receipt.id,
          "owner_visitor_id" => owner.id,
          "reason" => confirmation["reason"],
          "confirmation_nonce" => confirmation["confirmation_nonce"]
        }

        update!(
          ImportReceipt.revoke_changeset(receipt, %{
            status: "revoked",
            revoked_at: now,
            revocation_digest: Canonical.digest!(projection)
          })
        )
      end)
    end
  end

  def tombstone_export(%Visitor{} = owner, receipt_id, confirmation) do
    with :ok <- enabled(),
         :ok <- export_tombstone_confirmation(confirmation) do
      transaction(fn ->
        receipt =
          Repo.one(
            from(r in ExportReceipt,
              where: r.id == ^receipt_id and r.owner_visitor_id == ^owner.id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:export_receipt_not_found)

        if receipt.status == "tombstoned" do
          receipt
        else
          update!(
            ExportReceipt.transition_changeset(receipt, %{
              status: "tombstoned",
              tombstoned_at: DateTime.utc_now(),
              rotated_at: receipt.rotated_at
            })
          )
        end
      end)
    end
  end

  def continuity_status(%Visitor{} = owner) do
    imports =
      Repo.aggregate(
        from(r in ImportReceipt, where: r.owner_visitor_id == ^owner.id and r.status == "active"),
        :count
      )

    exports =
      Repo.aggregate(from(r in ExportReceipt, where: r.owner_visitor_id == ^owner.id), :count)

    %{
      "storage_scope" => "this_browser",
      "person_account" => false,
      "device_synced" => false,
      "recovered_import" => imports > 0,
      "encrypted_exports_created" => exports,
      "recovery_claim" => "requires_person_held_bundle_and_passphrase"
    }
  end

  defp import_record(owner, installation_ref, record) do
    origin_ref = origin_record_ref(installation_ref, record["id"])
    status = record["status"]

    if status == "active" and record["projection"] == "admitted" and is_binary(record["claim"]) do
      case destination_admission(owner, record["category"], record["claim"]) do
        {:unchanged, destination_id} ->
          item(origin_ref, status, "unchanged", destination_id)

        :conflict ->
          item(origin_ref, status, "conflict", nil)

        :admit ->
          attributes = %{
            category: record["category"],
            claim: record["claim"],
            creator: "user_explicit",
            owner_asserted: true,
            provenance: %{
              "basis" => "explicit_encrypted_import",
              "source_installation_ref" => installation_ref,
              "origin_record_ref" => origin_ref
            },
            sources: [],
            confidence: record["confidence"] || 1.0,
            valid_from: parse_time(record["valid_from"]),
            valid_until: parse_time(record["valid_until"]),
            confirmed_at: parse_time(record["confirmed_at"]),
            expires_at: parse_time(record["expires_at"])
          }

          case ProfileMemory.remember_explicit(owner, attributes) do
            {:ok, %{record: destination}} ->
              item(origin_ref, status, "imported", destination.id)

            {:error, reason} ->
              Repo.rollback({:portable_import_failed, reason})
          end
      end
    else
      apply_tombstone(owner, installation_ref, origin_ref, status)
    end
  end

  defp apply_tombstone(owner, installation_ref, origin_ref, source_status) do
    prior =
      Repo.one(
        from(i in ImportItem,
          join: r in ImportReceipt,
          on: r.id == i.import_receipt_id,
          where:
            r.owner_visitor_id == ^owner.id and
              r.source_installation_ref == ^installation_ref and
              i.origin_record_ref == ^origin_ref and not is_nil(i.destination_record_id),
          order_by: [desc: r.export_sequence],
          limit: 1
        )
      )

    if prior do
      forget_destination(owner, prior.destination_record_id)
      item(origin_ref, source_status, "tombstone_applied", prior.destination_record_id)
    else
      item(origin_ref, source_status, "tombstone_absent", nil)
    end
  end

  defp forget_destination(owner, record_id) do
    case ProfileMemory.get(owner, record_id) do
      {:ok, record} when record.status in ["active", "candidate"] ->
        case ProfileMemory.transition(owner, record.id, record.generation, "forgotten") do
          {:ok, _forgotten} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

      {:ok, _terminal} ->
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp destination_admission(owner, category, claim) do
    active =
      Repo.all(
        from(r in OpenAgents.ProfileMemory.Record,
          where: r.owner_visitor_id == ^owner.id and r.status == "active"
        )
      )

    case Enum.find(active, &(&1.category == category and &1.claim == claim)) do
      %{id: id} ->
        {:unchanged, id}

      nil ->
        category_count = Enum.count(active, &(&1.category == category))
        limit = Map.fetch!(category_limits(), category)

        total_count =
          Repo.aggregate(
            from(r in OpenAgents.ProfileMemory.Record, where: r.owner_visitor_id == ^owner.id),
            :count
          )

        if category_count >= limit or total_count >= @maximum_records,
          do: :conflict,
          else: :admit
    end
  end

  defp category_limits,
    do: %{
      "name" => 1,
      "role" => 1,
      "project" => 25,
      "preference" => 50,
      "constraint" => 25,
      "other" => 25
    }

  defp prevent_replay!(owner_id, installation_ref, sequence, envelope_digest) do
    replay? =
      Repo.exists?(
        from(r in ImportReceipt,
          where: r.owner_visitor_id == ^owner_id and r.envelope_digest == ^envelope_digest
        )
      )

    latest =
      Repo.one(
        from(r in ImportReceipt,
          where:
            r.owner_visitor_id == ^owner_id and r.source_installation_ref == ^installation_ref,
          select: max(r.export_sequence)
        )
      ) || 0

    cond do
      replay? -> Repo.rollback(:portable_bundle_replay)
      sequence <= latest -> Repo.rollback(:portable_bundle_stale)
      true -> :ok
    end
  end

  defp validate_payload(%{
         "schema" => @payload_schema,
         "source_installation_ref" => installation_ref,
         "export_sequence" => sequence,
         "profile" => %{"records" => records}
       })
       when is_binary(installation_ref) and is_integer(sequence) and sequence > 0 and
              is_list(records) and length(records) <= @maximum_records do
    valid_records =
      Enum.all?(records, fn record ->
        is_map(record) and is_binary(record["id"]) and
          match?({:ok, _}, Ecto.UUID.cast(record["id"])) and
          record["status"] in ~w(candidate active superseded forgotten expired)
      end)

    if Regex.match?(~r/\A[0-9a-f]{64}\z/, installation_ref) and valid_records,
      do: {:ok, %{installation_ref: installation_ref, sequence: sequence, records: records}},
      else: {:error, :invalid_portable_payload}
  end

  defp validate_payload(_), do: {:error, :invalid_portable_payload}

  defp import_confirmation(confirmation) do
    if confirmation["actor_type"] == "person" and confirmation["explicit"] == true and
         confirmation["confirmation_kind"] == "portable_memory_import" and
         bounded?(confirmation["confirmation_nonce"], 256),
       do: :ok,
       else: {:error, :explicit_import_confirmation_required}
  end

  defp revocation_confirmation(confirmation) do
    if confirmation["actor_type"] == "person" and confirmation["explicit"] == true and
         confirmation["confirmation_kind"] == "revoke_portable_import" and
         bounded?(confirmation["confirmation_nonce"], 256) and
         bounded?(confirmation["reason"], 500),
       do: :ok,
       else: {:error, :explicit_import_revocation_required}
  end

  defp export_tombstone_confirmation(confirmation) do
    if confirmation["actor_type"] == "person" and confirmation["explicit"] == true and
         confirmation["confirmation_kind"] == "tombstone_portable_export" and
         bounded?(confirmation["confirmation_nonce"], 256),
       do: :ok,
       else: {:error, :explicit_export_tombstone_required}
  end

  defp bounded?(value, maximum), do: is_binary(value) and byte_size(value) in 1..maximum

  defp enabled,
    do:
      if(Application.fetch_env!(:sarah, :memory_portability)[:enabled],
        do: :ok,
        else: {:error, :memory_portability_disabled}
      )

  defp installation_ref(owner_id), do: Canonical.sha256("portable-installation:v1:#{owner_id}")

  defp origin_record_ref(installation_ref, id),
    do: Canonical.sha256("portable-origin:v1:#{installation_ref}:#{id}")

  defp item(origin, status, disposition, destination),
    do: %{
      origin_record_ref: origin,
      source_status: status,
      disposition: disposition,
      destination_record_id: destination
    }

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> time
      _ -> nil
    end
  end

  defp latest_export(owner_id),
    do:
      Repo.one(
        from(r in ExportReceipt,
          where: r.owner_visitor_id == ^owner_id,
          order_by: [desc: r.sequence],
          limit: 1,
          lock: "FOR UPDATE"
        )
      )

  defp advisory_lock!(kind, value),
    do:
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "portability:#{kind}:#{value}"
      ])

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, row} -> row
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, row} -> row
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Repo.rollback(reason)
             value -> value
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end
end
