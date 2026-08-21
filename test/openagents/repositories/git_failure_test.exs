defmodule OpenAgents.Repositories.GitFailureTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Repositories.GitFailure

  test "classifies exhausted storage without exposing command output" do
    assert GitFailure.classify(
             "fatal: cannot create snapshot.bundle: No space left on device",
             :bundle_creation_failed
           ) == :insufficient_storage

    assert GitFailure.classify("error: Disk quota exceeded", :source_fetch_failed) ==
             :insufficient_storage
  end

  test "classifies an unavailable temporary filesystem" do
    assert GitFailure.classify("fatal: Permission denied", :bundle_creation_failed) ==
             :temporary_storage_unavailable

    assert GitFailure.classify("fatal: Read-only file system", :source_fetch_failed) ==
             :temporary_storage_unavailable
  end

  test "preserves the operation-specific fallback" do
    assert GitFailure.classify("fatal: malformed object", :bundle_creation_failed) ==
             :bundle_creation_failed
  end
end
