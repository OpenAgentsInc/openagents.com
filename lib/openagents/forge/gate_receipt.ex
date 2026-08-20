defmodule OpenAgents.Forge.GateReceipt do
  @moduledoc """
  Verifies the content-free, exact-SHA receipt required by release deployments.

  Receipts live under `.git`, not in the source tree. Changing the checked-out
  commit therefore invalidates the receipt without creating a commit that can
  attest to itself.
  """

  require Logger

  @schema "openagents.release-gate.v1"
  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @maximum_bytes 65_536
  @required_stages ~w(
    compile
    production_compile
    precommit
    cluster
    javascript
    direct_transaction
    relup
    version_chain
    interrupted_install
    rolling_replacement
    contracts
    release_smoke
  )

  @doc "Verify the local release-gate receipt for `sha`."
  def verify(sha, opts \\ [])

  def verify(sha, opts) when is_binary(sha) do
    if Regex.match?(@sha_pattern, sha) do
      case Keyword.get(opts, :emergency_override) do
        reason when is_binary(reason) and byte_size(reason) in 8..512 ->
          Logger.warning("release_gate_emergency_override sha=#{sha} reason=#{reason}")
          {:ok, %{schema: "openagents.release-gate.emergency.v1", git_sha: sha}}

        _no_override ->
          verify_receipt(sha, opts)
      end
    else
      {:error, :invalid_git_sha}
    end
  end

  def verify(_sha, _opts), do: {:error, :invalid_git_sha}

  @doc "Return the default receipt path for an exact Git SHA."
  def path(sha, opts \\ []) do
    root = Keyword.get_lazy(opts, :repo_root, &repo_root!/0)
    Path.join([root, ".git", "openagents", "release-gate-receipts", "#{sha}.json"])
  end

  defp verify_receipt(sha, opts) do
    with true <- Regex.match?(@sha_pattern, sha) or {:error, :invalid_git_sha},
         {:ok, stat} <- File.stat(path(sha, opts)),
         true <-
           (stat.type == :regular and stat.size <= @maximum_bytes) or
             {:error, :invalid_receipt_file},
         {:ok, bytes} <- File.read(path(sha, opts)),
         {:ok, receipt} <- Jason.decode(bytes),
         :ok <- validate(receipt, sha) do
      {:ok, receipt}
    else
      {:error, :enoent} -> {:error, :missing_gate_receipt}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_gate_receipt_json}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_gate_receipt}
    end
  end

  defp validate(receipt, sha) when is_map(receipt) do
    stages = Map.get(receipt, "stages", %{})

    cond do
      receipt["schema"] != @schema -> {:error, :wrong_gate_receipt_schema}
      receipt["git_sha"] != sha -> {:error, :stale_gate_receipt}
      receipt["status"] != "passed" -> {:error, :gate_not_passed}
      not complete_stages?(stages) -> {:error, :incomplete_gate_receipt}
      true -> :ok
    end
  end

  defp validate(_receipt, _sha), do: {:error, :invalid_gate_receipt}

  defp complete_stages?(stages) when is_map(stages) do
    Enum.all?(@required_stages, fn stage -> get_in(stages, [stage, "status"]) == "passed" end)
  end

  defp complete_stages?(_stages), do: false

  defp repo_root! do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> String.trim(root)
      {_output, _status} -> raise "release gate verification requires a Git worktree"
    end
  end
end
