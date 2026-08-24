defmodule OpenAgents.DataRights.AgeTest do
  @moduledoc """
  The claim under test is not "the bytes round trip". It is that a recipient
  holding a key the operator never saw can read the export **without the
  operator's software**, which is the only version of the claim worth
  publishing on `/status` (#178, `EXIT-006`).

  Three assertions carry it, and each covers what the others cannot:

  1. `age` itself decrypts what this module produces. This is the claim
     stated exactly. It runs wherever the binary is installed, and it is the
     assertion that ran when the decision landed.
  2. An independent decryptor written here from the specification decrypts it
     too, so the property is checked where `age` is not installed. On its own
     this would prove only that two of our own implementations agree.
  3. That decryptor reads a document the real `age` binary produced,
     checked in as a fixture. This pins our reading of the format to the
     reference implementation, which is what makes assertion 2 mean something
     when assertion 1 does not run.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.DataRights.Age

  @fixture_directory Path.expand("../../fixtures/age", __DIR__)
  @fixture_recipient "age1ja3nzz0wlmuqvsfhrx7w4kq00knnmu3ur32y47734k5javp4cqnqumg72a"
  @fixture_secret "AGE-SECRET-KEY-1XDUAFRZQALRUZ2G4UK6NDASFWPUFRTJ46359KD974PUPZ2UYXK2Q6G8QT3"
  @fixture_plaintext "openagents account export fixture\n"

  describe "parse_recipient/1" do
    test "accepts the age1… value age-keygen -y prints" do
      assert {:ok, key} = Age.parse_recipient(@fixture_recipient)
      assert byte_size(key) == 32
    end

    test "refuses a recipient whose checksum does not hold" do
      <<head::binary-size(byte_size(@fixture_recipient) - 1), last::binary>> = @fixture_recipient
      mutated = head <> if(last == "a", do: "q", else: "a")

      assert {:error, :invalid_recipient} = Age.parse_recipient(mutated)
    end

    test "refuses an identity, a bech32 string of another kind, and a non-binary" do
      assert {:error, :invalid_recipient} = Age.parse_recipient(@fixture_secret)

      assert {:error, :invalid_recipient} =
               Age.parse_recipient("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")

      assert {:error, :invalid_recipient} = Age.parse_recipient("")
      assert {:error, :invalid_recipient} = Age.parse_recipient(nil)
    end
  end

  describe "encrypt/2" do
    test "the age binary decrypts what this module produces" do
      case System.find_executable("age") do
        nil ->
          # Not a silent skip: the property is still asserted by the two tests
          # below, and this line says which half did not run.
          IO.puts(:stderr, "age binary absent: third-party decryption not exercised here")

        _path ->
          {:ok, recipient} = Age.parse_recipient(@fixture_recipient)
          plaintext = Jason.encode!(%{"account" => "export", "items" => Enum.to_list(1..2_000)})
          {:ok, sealed} = Age.encrypt(plaintext, recipient)

          directory = temporary_directory()
          identity = Path.join(directory, "identity.txt")
          document = Path.join(directory, "export.age")
          File.write!(identity, @fixture_secret <> "\n")
          File.write!(document, sealed)

          assert {decrypted, 0} =
                   System.cmd("age", ["--decrypt", "-i", identity, document])

          assert decrypted == plaintext
      end
    end

    test "an independent decryptor reads a single chunk, many chunks, and an empty document" do
      {:ok, recipient} = Age.parse_recipient(@fixture_recipient)

      for plaintext <- ["", "one line\n", :crypto.strong_rand_bytes(200_000)] do
        assert {:ok, sealed} = Age.encrypt(plaintext, recipient)
        assert decrypt(sealed, @fixture_secret) == plaintext
      end
    end

    test "the decryptor above reads a document the age binary produced" do
      reference = File.read!(Path.join(@fixture_directory, "reference.age"))

      assert decrypt(reference, @fixture_secret) == @fixture_plaintext
    end

    test "a truncated document does not open short" do
      {:ok, recipient} = Age.parse_recipient(@fixture_recipient)
      {:ok, sealed} = Age.encrypt(:crypto.strong_rand_bytes(200_000), recipient)
      truncated = binary_part(sealed, 0, byte_size(sealed) - 40)

      assert catch_error(decrypt(truncated, @fixture_secret))
    end

    test "two exports do not share a file key" do
      # Comparing the documents is not this assertion: the ephemeral X25519
      # key is fresh per call, so two documents differ byte for byte even
      # when every file key is identical. Recovering one file key would then
      # open every export ever issued, so the file key itself is what has to
      # be compared, and it is read back out of each document.
      {:ok, recipient} = Age.parse_recipient(@fixture_recipient)
      {:ok, first} = Age.encrypt("same plaintext", recipient)
      {:ok, second} = Age.encrypt("same plaintext", recipient)

      refute first == second
      refute file_key(first, @fixture_secret) == file_key(second, @fixture_secret)
    end

    test "refuses a recipient that is not 32 bytes" do
      assert {:error, :invalid_recipient} = Age.encrypt("body", <<0::128>>)
      assert {:error, :invalid_recipient} = Age.encrypt("body", "age1…")
    end

    test "refuses a low-order recipient, whose ciphertext anyone could read" do
      # `:crypto` raises on an all-zero peer key before the explicit
      # all-zero-shared-secret check can answer, so the refusal arrives as
      # `:encryption_failed`. Both guards are kept: the explicit one covers
      # the low-order points `:crypto` accepts.
      assert {:error, reason} = Age.encrypt("body", <<0::256>>)
      assert reason in [:invalid_recipient, :encryption_failed]
    end
  end

  defp temporary_directory do
    directory = Path.join(System.tmp_dir!(), "age-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    directory
  end

  defdelegate decrypt(document, identity), to: OpenAgents.Test.AgeDocument
  defdelegate file_key(document, identity), to: OpenAgents.Test.AgeDocument
end
