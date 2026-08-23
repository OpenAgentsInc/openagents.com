defmodule OpenAgents.DeploymentsFixtures do
  @moduledoc """
  Test helpers for the deployment control plane.

  Requests are created with an explicit commit store, so a test proves policy and
  authority without needing real git storage. The commit check itself is proved
  separately.
  """

  alias OpenAgents.Deployments
  alias OpenAgents.Deployments.Principal

  @commit String.duplicate("ab", 20)
  @artifact "sha256:" <> String.duplicate("c", 64)

  @doc "A full commit sha every fixture agrees on."
  def commit_sha, do: @commit

  @doc "An artifact digest every fixture agrees on."
  def artifact_digest, do: @artifact

  @doc "A commit store that admits every commit, for tests about policy."
  def any_commit, do: fn _repository, _commit_sha -> :ok end

  @doc "Define one environment with the given protection policy."
  def environment_fixture(repository, user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "name" => "production",
          "kind" => "production",
          "provider" => "fake",
          "protection" => %{}
        },
        stringify(attrs)
      )

    {:ok, environment} = Deployments.put_environment(repository, Principal.user(user), attrs)
    environment
  end

  @doc "Record one deployment request and return its run."
  def run_fixture(repository, user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "environment" => "production",
          "commit_sha" => @commit,
          "artifact_digest" => @artifact,
          "source_ref" => "refs/heads/main",
          "idempotency_key" => "idempotency-" <> Integer.to_string(unique())
        },
        stringify(attrs)
      )

    {:ok, run} =
      Deployments.request_deployment(repository, Principal.user(user), attrs,
        commit_store: any_commit()
      )

    run
  end

  @doc "Issue a workflow grant and return the grant with its plaintext token."
  def workflow_grant_fixture(repository, user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "audience" => "openagents-deployments",
          "scopes" => ["deployments:request", "deployments:checks"],
          "source_ref" => "refs/heads/main",
          "source_workflow" => "deploy.yml",
          "workflow_run_id" => "wfr-" <> Integer.to_string(unique())
        },
        stringify(attrs)
      )

    {:ok, {grant, plaintext}} =
      Deployments.issue_workflow_grant(repository, Principal.user(user), attrs)

    {grant, plaintext}
  end

  defp stringify(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])
end
