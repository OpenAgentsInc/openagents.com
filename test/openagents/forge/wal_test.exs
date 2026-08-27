defmodule OpenAgents.Forge.WALTest do
  use ExUnit.Case, async: false
  alias OpenAgents.Forge.WAL

  setup {Req.Test, :verify_on_exit!}

  @repo "openagents.com"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "openagents_forge_wal_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    previous_dir = Application.fetch_env(:openagents, :forge_wal_dir)
    previous_adapter = Application.fetch_env(:openagents, :forge_wal_adapter)

    Application.put_env(:openagents, :forge_wal_dir, tmp_dir)
    Application.put_env(:openagents, :forge_wal_adapter, OpenAgents.Forge.WAL.Local)

    on_exit(fn ->
      restore_env(:forge_wal_dir, previous_dir)
      restore_env(:forge_wal_adapter, previous_adapter)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:openagents, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:openagents, key)

  defp entry(index, refs, principal \\ "test") do
    seq = WAL.next_seq(index)
    payload = "payload-#{seq}"
    {:ok, key} = WAL.put_entry(@repo, seq, payload)

    %{
      "seq" => seq,
      "object" => key,
      "refs" => refs,
      "principal" => principal,
      "pushed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  describe "cas_index/3 create-if-absent" do
    test "succeeds when the index is absent and conflicts once it exists" do
      assert {:error, :not_found} = WAL.read_index(@repo)
      assert {:ok, generation} = WAL.cas_index(@repo, :none, WAL.new_index())
      assert {:error, :cas_conflict} = WAL.cas_index(@repo, :none, WAL.new_index())

      assert {:ok, ^generation, index} = WAL.read_index(@repo)
      assert index == WAL.new_index()
      refute Map.has_key?(index, "generation")
    end

    test "conflicts for an integer generation when the index is absent" do
      assert {:error, :cas_conflict} = WAL.cas_index(@repo, 1, WAL.new_index())
    end
  end

  describe "cas_index/3 read/CAS round trip" do
    test "bumps the generation and persists the new index" do
      {:ok, gen0} = WAL.cas_index(@repo, :none, WAL.new_index())
      {:ok, ^gen0, index} = WAL.read_index(@repo)

      refs = %{"refs/heads/main" => String.duplicate("a", 40)}
      updated = WAL.append_entry(index, entry(index, refs))

      assert {:ok, gen1} = WAL.cas_index(@repo, gen0, updated)
      assert gen1 == gen0 + 1

      assert {:ok, ^gen1, read_back} = WAL.read_index(@repo)
      assert read_back == updated
      assert WAL.refs(read_back) == refs
      assert WAL.next_seq(read_back) == 1
    end

    test "a stale generation returns :cas_conflict and loses no data" do
      {:ok, gen0} = WAL.cas_index(@repo, :none, WAL.new_index())
      {:ok, ^gen0, index} = WAL.read_index(@repo)

      refs = %{"refs/heads/main" => String.duplicate("b", 40)}
      updated = WAL.append_entry(index, entry(index, refs))
      {:ok, gen1} = WAL.cas_index(@repo, gen0, updated)

      assert {:error, :cas_conflict} = WAL.cas_index(@repo, gen0, WAL.new_index())

      assert {:ok, ^gen1, read_back} = WAL.read_index(@repo)
      assert read_back == updated
    end
  end

  describe "put_entry/3 and get_entry/2" do
    test "round trips a payload and derives a stable content-addressed key" do
      payload = :crypto.strong_rand_bytes(256)

      assert {:ok, key} = WAL.put_entry(@repo, 0, payload)
      assert key =~ ~r/^entries\/00000000-[0-9a-f]{12}$/
      assert {:ok, ^key} = WAL.put_entry(@repo, 0, payload)
      assert {:ok, ^payload} = WAL.get_entry(@repo, key)
    end

    test "a missing entry returns :not_found" do
      assert {:error, :not_found} =
               WAL.get_entry(@repo, "entries/00000042-0123456789ab")
    end

    test "a malformed object key is rejected" do
      assert {:error, :invalid_object_key} = WAL.get_entry(@repo, "../escape")
    end

    test "streams a file into and out of the WAL under the same content key", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "source.bundle")
      destination = Path.join(tmp_dir, "downloaded.bundle")
      payload = :crypto.strong_rand_bytes(4 * 1_024 * 1_024)
      File.write!(source, payload)

      assert {:ok, key} = WAL.put_entry_file(@repo, 0, source)
      assert key == WAL.entry_key(0, payload)
      assert :ok = WAL.get_entry_file(@repo, key, destination)
      assert File.stat!(destination).size == byte_size(payload)
      assert :crypto.hash(:sha256, File.read!(destination)) == :crypto.hash(:sha256, payload)
    end
  end

  describe "delete_repo/1" do
    test "removes the index and every immutable object for one repository" do
      payload = "repository payload"
      assert {:ok, key} = WAL.put_entry(@repo, 0, payload)

      index =
        WAL.new_index()
        |> WAL.append_entry(%{
          "seq" => 0,
          "object" => key,
          "refs" => %{"refs/heads/main" => String.duplicate("a", 40)},
          "principal" => "test",
          "pushed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert {:ok, _generation} = WAL.cas_index(@repo, :none, index)
      assert :ok = WAL.delete_repo(@repo)
      assert {:error, :not_found} = WAL.read_index(@repo)
      assert {:error, :not_found} = WAL.get_entry(@repo, key)
      assert :ok = WAL.delete_repo(@repo)
    end
  end

  describe "digest-addressed artifacts" do
    test "round trips only under the payload's full SHA-256" do
      payload = :crypto.strong_rand_bytes(512)

      digest =
        :sha256
        |> :crypto.hash(payload)
        |> Base.encode16(case: :lower)

      assert {:ok, "artifacts/" <> ^digest <> ".tar"} =
               WAL.put_artifact(@repo, digest, payload)

      assert {:ok, ^payload} = WAL.get_artifact(@repo, digest)

      assert {:error, :artifact_digest_mismatch} =
               WAL.put_artifact(@repo, String.duplicate("0", 64), payload)

      assert {:error, :invalid_object_key} = WAL.get_artifact(@repo, String.duplicate("a", 40))
    end
  end

  describe "repo validation" do
    test "rejects invalid repo names on every dispatcher function" do
      for bad <- ["Uppercase", "a/b", "", "-lead", "bad..git", :openagents] do
        assert {:error, :invalid_repo} = WAL.read_index(bad)
        assert {:error, :invalid_repo} = WAL.cas_index(bad, :none, WAL.new_index())
        assert {:error, :invalid_repo} = WAL.put_entry(bad, 0, "x")
        assert {:error, :invalid_repo} = WAL.put_entry_file(bad, 0, "/tmp/entry")
        assert {:error, :invalid_repo} = WAL.get_entry(bad, "entries/00000000-0123456789ab")
        assert {:error, :invalid_repo} = WAL.delete_repo(bad)

        assert {:error, :invalid_repo} =
                 WAL.get_entry_file(bad, "entries/00000000-0123456789ab", "/tmp/entry")
      end
    end
  end

  describe "pure helpers" do
    test "new_index/0, next_seq/1, and refs/1" do
      index = WAL.new_index()
      assert index == %{"version" => 1, "entries" => [], "refs" => %{}}
      assert WAL.next_seq(index) == 0
      assert WAL.refs(index) == %{}
    end

    test "append_entry/2 appends and replaces the top-level refs" do
      refs0 = %{"refs/heads/main" => String.duplicate("0", 40)}
      refs1 = %{"refs/heads/main" => String.duplicate("1", 40)}

      index = WAL.new_index()
      index = WAL.append_entry(index, entry(index, refs0))
      index = WAL.append_entry(index, entry(index, refs1))

      assert WAL.next_seq(index) == 2
      assert WAL.refs(index) == refs1
      assert Enum.map(index["entries"], & &1["seq"]) == [0, 1]
    end

    test "append_entry/2 raises on a wrong sequence number" do
      index = WAL.new_index()

      wrong = %{
        "seq" => 3,
        "object" => "entries/00000003-0123456789ab",
        "refs" => %{},
        "principal" => "test",
        "pushed_at" => "2026-08-18T00:00:00Z"
      }

      assert_raise ArgumentError, ~r/does not match next seq 0/, fn ->
        WAL.append_entry(index, wrong)
      end
    end

    test "append_entry/2 chains each entry to the one before it" do
      refs0 = %{"refs/heads/main" => String.duplicate("0", 40)}
      refs1 = %{"refs/heads/main" => String.duplicate("1", 40)}

      index = WAL.new_index()
      index = WAL.append_entry(index, entry(index, refs0))
      index = WAL.append_entry(index, entry(index, refs1))

      [first, second] = index["entries"]

      assert {:ok, first["link"]} == WAL.chain_link("", Map.delete(first, "link"))
      assert {:ok, second["link"]} == WAL.chain_link(first["link"], Map.delete(second, "link"))
      assert WAL.previous_link(index["entries"]) == second["link"]
    end

    test "chain_link/2 is deterministic, and every field is inside it" do
      base = %{
        "seq" => 1,
        "object" => "entries/00000001-0123456789ab",
        "refs" => %{"refs/heads/main" => "abc", "refs/heads/topic" => "def"},
        "principal" => "user:1",
        "pushed_at" => "2026-08-18T00:00:00Z"
      }

      assert {:ok, link} = WAL.chain_link("prev", base)
      assert {:ok, ^link} = WAL.chain_link("prev", base)
      assert link =~ ~r/^[0-9a-f]{64}$/

      # Reordering a map does not change it; changing any field does.
      reordered =
        base
        |> Map.delete("refs")
        |> Map.put("refs", %{
          "refs/heads/topic" => "def",
          "refs/heads/main" => "abc"
        })

      assert {:ok, ^link} = WAL.chain_link("prev", reordered)

      for altered <- [
            Map.put(base, "seq", 2),
            Map.put(base, "object", "entries/00000001-0123456789ac"),
            Map.put(base, "principal", "user:2"),
            Map.put(base, "pushed_at", "2026-08-18T00:00:01Z"),
            Map.put(base, "refs", %{"refs/heads/main" => "abd", "refs/heads/topic" => "def"}),
            Map.put(base, "format", "git_bundle"),
            Map.delete(base, "principal")
          ] do
        assert {:ok, other} = WAL.chain_link("prev", altered)
        refute other == link
      end

      assert {:ok, moved} = WAL.chain_link("other-prev", base)
      refute moved == link
    end

    test "chain_link/2 pins one encoding, so a refactor cannot silently relink a log" do
      # A golden vector. Every link ever written depends on this encoding, so a
      # change to it turns every existing log into apparent tampering. Changing
      # the digest below is a decision, not a fix.
      entry = %{
        "seq" => 1,
        "object" => "entries/00000001-0123456789ab",
        "format" => "receive_pack",
        "refs" => %{"refs/heads/main" => "aaaa", "refs/heads/topic" => "bbbb"},
        "principal" => "user:1",
        "pushed_at" => "2026-08-18T00:00:00Z",
        "shallow" => []
      }

      assert WAL.chain_link("0000", entry) ==
               {:ok, "d4998407fec7456d6295a9961e95925efa94716291517cf3a4fbfac7eba0d633"}
    end

    test "chain_link/2 survives the JSON round trip the index actually takes" do
      # An entry is linked in memory, encoded to JSON, stored, and decoded again
      # before the verifier recomputes the link. Anything the encoding depends
      # on that JSON does not preserve would break every stored log.
      refs =
        Map.new(1..40, fn i -> {"refs/heads/b#{i}", String.duplicate("#{rem(i, 10)}", 40)} end)

      index =
        WAL.new_index()
        |> WAL.append_entry(entry(WAL.new_index(), refs))

      [stored] = index |> Jason.encode!() |> Jason.decode!() |> WAL.entries()
      [original] = WAL.entries(index)

      assert stored == original
      assert {:ok, stored["link"]} == WAL.chain_link("", Map.delete(stored, "link"))
    end

    test "chain_link/2 never raises, so no push can fail on it" do
      # A push must survive anything that reaches the entry map. The link is
      # omitted rather than raised, and the gap becomes a verifier finding.
      for entry <- [
            %{"seq" => 0, "weird" => {:a, self()}},
            %{"seq" => 0, "when" => DateTime.utc_now()},
            %{"seq" => 0, "list" => [1, :two, "three", nil, 4.5, %{"k" => false}]},
            %{}
          ] do
        assert {:ok, link} = WAL.chain_link("", entry)
        assert link =~ ~r/^[0-9a-f]{64}$/
      end

      assert :error = WAL.chain_link("", "not a map")
      assert :error = WAL.chain_link(nil, %{})
    end

    test "entry_link/1 and previous_link/1 read an unchained log as the chain start" do
      unchained = %{"seq" => 0, "refs" => %{}}

      assert WAL.entry_link(unchained) == nil
      assert WAL.previous_link([]) == ""
      assert WAL.previous_link([unchained]) == ""
      assert WAL.previous_link([Map.put(unchained, "link", "abc")]) == "abc"
    end

    test "entry_key/2 is deterministic and padded" do
      assert WAL.entry_key(7, "abc") == WAL.entry_key(7, "abc")
      assert WAL.entry_key(7, "abc") =~ ~r/^entries\/00000007-[0-9a-f]{12}$/
      refute WAL.entry_key(7, "abc") == WAL.entry_key(7, "abd")
    end
  end

  describe "concurrent CAS" do
    test "no lost updates across 20 concurrent single-attempt writers" do
      {:ok, _gen} = WAL.cas_index(@repo, :none, WAL.new_index())

      results =
        1..20
        |> Enum.map(fn writer ->
          Task.async(fn ->
            {:ok, generation, index} = WAL.read_index(@repo)
            seq = WAL.next_seq(index)
            {:ok, key} = WAL.put_entry(@repo, seq, "writer-#{writer}")

            updated =
              WAL.append_entry(index, %{
                "seq" => seq,
                "object" => key,
                "refs" => %{"refs/heads/main" => String.pad_leading("#{writer}", 40, "0")},
                "principal" => "writer-#{writer}",
                "pushed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              })

            WAL.cas_index(@repo, generation, updated)
          end)
        end)
        |> Task.await_many(30_000)

      successes = Enum.count(results, &match?({:ok, _generation}, &1))
      conflicts = Enum.count(results, &match?({:error, :cas_conflict}, &1))

      assert successes >= 1
      assert successes + conflicts == 20

      {:ok, final_generation, final_index} = WAL.read_index(@repo)

      # Every successful CAS appended exactly one entry and bumped the
      # generation exactly once — nothing was overwritten or lost.
      assert length(final_index["entries"]) == successes
      assert final_generation == 1 + successes
      assert Enum.map(final_index["entries"], & &1["seq"]) == Enum.to_list(0..(successes - 1))
    end
  end

  describe "GCS adapter (offline)" do
    setup do
      OpenAgents.Forge.WAL.Gcs.reset_index_cache()
      :ok
    end

    test "returns :not_configured when no bucket is set" do
      previous = Application.fetch_env(:openagents, :forge_wal_bucket)
      Application.delete_env(:openagents, :forge_wal_bucket)
      on_exit(fn -> restore_env(:forge_wal_bucket, previous) end)

      assert {:error, :not_configured} = OpenAgents.Forge.WAL.Gcs.read_index(@repo)

      assert {:error, :not_configured} =
               OpenAgents.Forge.WAL.Gcs.cas_index(@repo, :none, WAL.new_index())

      assert {:error, :not_configured} = OpenAgents.Forge.WAL.Gcs.put_entry(@repo, 0, "x")
      assert {:error, :not_configured} = OpenAgents.Forge.WAL.Gcs.delete_repo(@repo)

      assert {:error, :not_configured} =
               OpenAgents.Forge.WAL.Gcs.put_entry_file(@repo, 0, "/tmp/entry")

      assert {:error, :not_configured} =
               OpenAgents.Forge.WAL.Gcs.get_entry(@repo, "entries/00000000-0123456789ab")

      assert {:error, :not_configured} =
               OpenAgents.Forge.WAL.Gcs.get_entry_file(
                 @repo,
                 "entries/00000000-0123456789ab",
                 "/tmp/entry"
               )
    end

    test "reuses a decoded index while the GCS generation is unchanged" do
      previous_bucket = Application.fetch_env(:openagents, :forge_wal_bucket)
      previous_provider = Application.fetch_env(:openagents, :forge_gcs_token_provider)
      previous_options = Application.fetch_env(:openagents, :forge_gcs_request_options)

      Application.put_env(:openagents, :forge_wal_bucket, "test-bucket")
      Application.put_env(:openagents, :forge_gcs_token_provider, fn -> "test-token" end)

      Application.put_env(:openagents, :forge_gcs_request_options, plug: {Req.Test, __MODULE__})

      on_exit(fn ->
        restore_env(:forge_wal_bucket, previous_bucket)
        restore_env(:forge_gcs_token_provider, previous_provider)
        restore_env(:forge_gcs_request_options, previous_options)
      end)

      index = WAL.new_index()

      Req.Test.expect(__MODULE__, fn request ->
        assert request.query_string == "fields=generation"
        Req.Test.json(request, %{"generation" => "42"})
      end)

      Req.Test.expect(__MODULE__, fn request ->
        assert request.query_string == "alt=media"
        Req.Test.json(request, index)
      end)

      Req.Test.expect(__MODULE__, fn request ->
        assert request.query_string == "fields=generation"
        Req.Test.json(request, %{"generation" => "42"})
      end)

      assert {:ok, "42", ^index} = OpenAgents.Forge.WAL.Gcs.read_index(@repo)
      assert {:ok, "42", ^index} = OpenAgents.Forge.WAL.Gcs.read_index(@repo)
    end

    test "object naming helpers" do
      assert OpenAgents.Forge.WAL.Gcs.prefix("openagents.com") == "forge/wal/openagents.com/"

      assert OpenAgents.Forge.WAL.Gcs.index_object("openagents.com") ==
               "forge/wal/openagents.com/index.json"

      assert OpenAgents.Forge.WAL.Gcs.object_name(
               "openagents.com",
               "entries/00000000-0123456789ab"
             ) ==
               "forge/wal/openagents.com/entries/00000000-0123456789ab"
    end
  end
end
