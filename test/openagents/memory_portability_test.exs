defmodule OpenAgents.MemoryPortabilityTest do
  use OpenAgents.SarahDataCase, async: false
  import ExUnit.CaptureLog

  alias OpenAgents.{Conversations, ProfileMemory}
  alias OpenAgents.Memory.Portability
  alias OpenAgents.Memory.Portability.{Envelope, ExportReceipt, ImportItem, ImportReceipt}

  @passphrase "correct horse battery staple for Sarah"

  setup do
    original = Application.fetch_env!(:openagents, :memory_portability)
    Application.put_env(:openagents, :memory_portability, enabled: true)
    on_exit(fn -> Application.put_env(:openagents, :memory_portability, original) end)
    :ok
  end

  test "versioned envelope interoperates, authenticates metadata, and rejects loss or tampering" do
    payload = %{"schema" => "fixture.v1", "records" => [%{"claim" => "private value"}]}
    assert {:ok, encoded} = Envelope.seal(payload, @passphrase)
    assert {:ok, ^payload} = Envelope.open(encoded, @passphrase)
    assert {:error, :decryption_failed} = Envelope.open(encoded, "wrong passphrase long enough")

    tampered =
      encoded
      |> Jason.decode!()
      |> put_in(
        ["cipher", "nonce"],
        Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )
      |> OpenAgents.Provenance.Canonical.encode!()

    assert {:error, :decryption_failed} = Envelope.open(tampered, @passphrase)

    unsupported =
      encoded
      |> Jason.decode!()
      |> Map.put("schema", "sarah.portable_memory_envelope.v2")
      |> OpenAgents.Provenance.Canonical.encode!()

    assert {:error, :unsupported_envelope} = Envelope.open(unsupported, @passphrase)
  end

  test "adapter failure or disablement leaves browser-local memory available" do
    owner = visitor!("portable-disabled")
    remember!(owner, "other", "This remains browser-local.")
    Application.put_env(:openagents, :memory_portability, enabled: false)

    assert {:error, :memory_portability_disabled} =
             Portability.export_bundle(owner, @passphrase)

    assert {:ok, current} = ProfileMemory.list_current(owner)
    assert Enum.any?(current, &(&1.claim == "This remains browser-local."))
    assert Portability.continuity_status(owner)["storage_scope"] == "this_browser"
  end

  test "a new browser requires bundle, passphrase, and explicit person confirmation" do
    source = visitor!("portable-source")
    destination = visitor!("portable-destination")
    remember!(source, "project", "The launch project is Atlas.")
    assert {:ok, exported} = Portability.export_bundle(source, @passphrase)

    assert {:error, :explicit_import_confirmation_required} =
             Portability.import_bundle(destination, exported.envelope, @passphrase, %{})

    assert {:error, :decryption_failed} =
             Portability.import_bundle(
               destination,
               exported.envelope,
               "lost recovery passphrase",
               import_confirmation("wrong-key")
             )

    assert {:ok, imported} =
             Portability.import_bundle(
               destination,
               exported.envelope,
               @passphrase,
               import_confirmation("first-device")
             )

    assert imported.receipt.imported_count == 1
    assert imported.receipt.conflict_count == 0
    assert {:ok, destination_records} = ProfileMemory.list_current(destination)
    assert Enum.any?(destination_records, &(&1.claim == "The launch project is Atlas."))

    assert Portability.continuity_status(destination) == %{
             "storage_scope" => "this_browser",
             "person_account" => false,
             "device_synced" => false,
             "recovered_import" => true,
             "encrypted_exports_created" => 0,
             "recovery_claim" => "requires_person_held_bundle_and_passphrase"
           }

    assert {:error, :portable_bundle_replay} =
             Portability.import_bundle(
               destination,
               exported.envelope,
               @passphrase,
               import_confirmation("replay")
             )
  end

  test "fresh exports rotate sequence, reject stale replay, and carry durable tombstones" do
    source = visitor!("portable-rotation-source")
    destination = visitor!("portable-rotation-destination")
    source_record = remember!(source, "project", "Use the Borealis release plan.")
    assert {:ok, first} = Portability.export_bundle(source, @passphrase)

    assert {:ok, first_import} =
             Portability.import_bundle(
               destination,
               first.envelope,
               @passphrase,
               import_confirmation("sequence-1")
             )

    second_passphrase = "rotated person-held passphrase for Sarah"
    assert {:ok, second} = Portability.export_bundle(source, second_passphrase)
    assert Repo.get!(ExportReceipt, first.receipt.id).status == "rotated"
    assert second.receipt.sequence == first.receipt.sequence + 1
    assert Envelope.open(second.envelope, @passphrase) == {:error, :decryption_failed}

    assert {:ok, second_import} =
             Portability.import_bundle(
               destination,
               second.envelope,
               second_passphrase,
               import_confirmation("sequence-2")
             )

    assert second_import.receipt.unchanged_count == 1

    assert {:error, :portable_bundle_replay} =
             Portability.import_bundle(
               destination,
               first.envelope,
               @passphrase,
               import_confirmation("old-copy")
             )

    assert {:ok, _forgotten} =
             ProfileMemory.transition(
               source,
               source_record.id,
               source_record.generation,
               "forgotten"
             )

    assert {:ok, tombstone_bundle} = Portability.export_bundle(source, second_passphrase)

    assert {:ok, tombstone_import} =
             Portability.import_bundle(
               destination,
               tombstone_bundle.envelope,
               second_passphrase,
               import_confirmation("sequence-3-tombstone")
             )

    assert tombstone_import.receipt.tombstone_count == 1
    assert {:ok, current} = ProfileMemory.list_current(destination)
    refute Enum.any?(current, &(&1.claim == "Use the Borealis release plan."))

    assert {:ok, tombstoned_export} =
             Portability.tombstone_export(source, tombstone_bundle.receipt.id, %{
               "actor_type" => "person",
               "explicit" => true,
               "confirmation_kind" => "tombstone_portable_export",
               "confirmation_nonce" => "retire-sequence-3"
             })

    assert tombstoned_export.status == "tombstoned"
    assert first_import.receipt.status == "active"
  end

  test "revoking a recovered device forgets imported claims without affecting the source" do
    source = visitor!("portable-revoke-source")
    destination = visitor!("portable-revoke-destination")
    remember!(source, "constraint", "Never publish the draft automatically.")
    assert {:ok, export} = Portability.export_bundle(source, @passphrase)

    assert {:ok, import} =
             Portability.import_bundle(
               destination,
               export.envelope,
               @passphrase,
               import_confirmation("recover-device")
             )

    assert {:ok, revoked} =
             Portability.revoke_import(destination, import.receipt.id, %{
               "actor_type" => "person",
               "explicit" => true,
               "confirmation_kind" => "revoke_portable_import",
               "confirmation_nonce" => "lost-device-revoke",
               "reason" => "The recovered browser is no longer trusted."
             })

    assert revoked.status == "revoked"
    assert revoked.revocation_digest =~ ~r/^[0-9a-f]{64}$/
    assert {:ok, destination_current} = ProfileMemory.list_current(destination)
    assert destination_current == []
    assert {:ok, source_current} = ProfileMemory.list_current(source)
    assert Enum.any?(source_current, &(&1.claim == "Never publish the draft automatically."))
  end

  test "destination conflicts are explicit and portability storage contains no envelope or claim" do
    source = visitor!("portable-conflict-source")
    destination = visitor!("portable-conflict-destination")
    remember!(source, "name", "My name is Ada.")
    remember!(destination, "name", "My name is Grace.")
    assert {:ok, export} = Portability.export_bundle(source, @passphrase)

    log =
      capture_log(fn ->
        assert {:ok, result} =
                 Portability.import_bundle(
                   destination,
                   export.envelope,
                   @passphrase,
                   import_confirmation("conflict")
                 )

        assert result.receipt.conflict_count == 1
      end)

    refute log =~ "My name is Ada."
    refute log =~ export.envelope

    export_columns = ExportReceipt.__schema__(:fields)
    import_columns = ImportReceipt.__schema__(:fields)
    item_columns = ImportItem.__schema__(:fields)

    for forbidden <- [:envelope, :ciphertext, :plaintext, :claim, :payload] do
      refute forbidden in export_columns
      refute forbidden in import_columns
      refute forbidden in item_columns
    end
  end

  defp visitor!(browser_key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)
  end

  defp remember!(owner, category, claim) do
    assert {:ok, %{record: record}} =
             ProfileMemory.remember_explicit(owner, %{
               category: category,
               claim: claim,
               creator: "user_explicit",
               owner_asserted: true,
               provenance: %{"basis" => "test-owner-assertion"},
               sources: [],
               confidence: 1.0
             })

    record
  end

  defp import_confirmation(nonce),
    do: %{
      "actor_type" => "person",
      "explicit" => true,
      "confirmation_kind" => "portable_memory_import",
      "confirmation_nonce" => nonce
    }
end
