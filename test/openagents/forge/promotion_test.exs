defmodule OpenAgents.Forge.PromotionTest do
  @moduledoc """
  `OpenAgents.Forge.Promotion` is the one authority path for fleet promotion.
  Both callers — the `/admin/forge` button and the operator API — reach it, so
  the policy proved here is the policy both surfaces get.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.ForgePromotionFixtures

  alias OpenAgents.AuditEvent
  alias OpenAgents.Forge.{Promotion, Target, Targets}
  alias OpenAgents.Repo

  @repo "openagents.com"

  setup do
    isolate_forge_storage!()
    :ok
  end

  defp attrs(sha, overrides \\ %{}) do
    Map.merge(
      %{
        "environment" => "production",
        "idempotency_key" => "key-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        "repo" => @repo,
        "sha" => sha,
        "source" => "api"
      },
      overrides
    )
  end

  test "an operator promotes an exact pushed SHA and the target carries the operator identity" do
    operator = operator_fixture("promotion-operator")
    sha = seeded_commit(@repo)

    assert {:ok, %{target: target, replayed: false}} = Promotion.promote(operator, attrs(sha))
    assert target.sha == sha
    assert target.repo == @repo
    assert target.status == "promoted"
    assert target.promoted_by == "operator:#{operator.github_id}"
    assert target.details["promotion_source"] == "api"
    assert target.details["promoted_by_user_id"] == operator.id
    assert target.details["promotion_environment"] == "production"
  end

  test "the console and the API produce the same lifecycle event and receipt shape" do
    operator = operator_fixture("promotion-both-surfaces")
    console_sha = seeded_commit(@repo, "console")
    api_sha = seeded_commit(@repo, "api")

    console_attrs = %{
      "environment" => "production",
      "repo" => @repo,
      "sha" => console_sha,
      "source" => "operator_console"
    }

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:target")

    assert {:ok, %{target: console}} = Promotion.promote(operator, console_attrs)
    assert_receive {:forge_target, %{sha: ^console_sha}}

    assert {:ok, %{target: api}} = Promotion.promote(operator, attrs(api_sha))
    assert_receive {:forge_target, %{sha: ^api_sha}}

    assert console.promoted_by == api.promoted_by
    assert console.status == api.status
    assert console.details["promotion_source"] == "operator_console"
    assert api.details["promotion_source"] == "api"
  end

  test "a non-operator is refused, with or without a well-formed request" do
    ordinary = promotion_user_fixture("promotion-ordinary")
    sha = seeded_commit(@repo)

    assert {:error, :not_operator} = Promotion.promote(ordinary, attrs(sha))
    assert {:error, :not_operator} = Promotion.promote(nil, attrs(sha))
    assert Repo.aggregate(Target, :count) == 0
  end

  test "losing operator standing stops the next promotion" do
    operator = operator_fixture("promotion-revoked")
    first = seeded_commit(@repo, "first")
    second = seeded_commit(@repo, "second")

    assert {:ok, _promotion} = Promotion.promote(operator, attrs(first))

    revoke_operator(operator)

    assert {:error, :not_operator} = Promotion.promote(operator, attrs(second))
    assert Repo.aggregate(Target, :count) == 1
  end

  test "a branch name, an abbreviation, an unknown SHA, and a foreign repository are refused" do
    operator = operator_fixture("promotion-exactness")
    sha = seeded_commit(@repo)

    assert {:error, :invalid_sha} = Promotion.promote(operator, attrs("main"))
    assert {:error, :invalid_sha} = Promotion.promote(operator, attrs(String.slice(sha, 0, 12)))
    assert {:error, :unknown_sha} = Promotion.promote(operator, attrs(String.duplicate("a", 40)))

    assert {:error, :repository_not_deployable} =
             Promotion.promote(operator, attrs(sha, %{"repo" => "someone-elses-repo"}))

    assert Repo.aggregate(Target, :count) == 0
  end

  test "only the production environment is admitted" do
    operator = operator_fixture("promotion-environment")
    sha = seeded_commit(@repo)

    assert {:error, :unsupported_environment} =
             Promotion.promote(operator, attrs(sha, %{"environment" => "preview"}))

    assert {:error, :unsupported_environment} =
             Promotion.promote(operator, attrs(sha, %{"environment" => nil}))
  end

  test "an API promotion requires a caller-generated idempotency key" do
    operator = operator_fixture("promotion-key-required")
    sha = seeded_commit(@repo)

    assert {:error, :invalid_idempotency_key} =
             Promotion.promote(operator, attrs(sha, %{"idempotency_key" => nil}))

    assert {:error, :invalid_idempotency_key} =
             Promotion.promote(operator, attrs(sha, %{"idempotency_key" => "short"}))
  end

  test "an identical retry returns the original target and a different payload conflicts" do
    operator = operator_fixture("promotion-idempotent")
    sha = seeded_commit(@repo, "one")
    other = seeded_commit(@repo, "two")
    request = attrs(sha, %{"idempotency_key" => "release-2026-08-23-0001"})

    assert {:ok, %{target: first, replayed: false}} = Promotion.promote(operator, request)
    assert {:ok, %{target: replayed, replayed: true}} = Promotion.promote(operator, request)
    assert replayed.id == first.id
    assert Repo.aggregate(Target, :count) == 1

    assert {:error, :idempotency_conflict} =
             Promotion.promote(operator, %{request | "sha" => other})

    assert Repo.aggregate(Target, :count) == 1
  end

  test "an expected-current-target precondition refuses a superseded promotion" do
    operator = operator_fixture("promotion-precondition")
    first = seeded_commit(@repo, "first")
    second = seeded_commit(@repo, "second")
    third = seeded_commit(@repo, "third")

    assert {:ok, %{target: original}} = Promotion.promote(operator, attrs(first))

    assert {:ok, %{target: current}} =
             Promotion.promote(
               operator,
               attrs(second, %{"expected_current_target_id" => original.id})
             )

    assert {:error, :precondition_failed} =
             Promotion.promote(
               operator,
               attrs(third, %{"expected_current_target_id" => original.id})
             )

    assert Targets.current(@repo).id == current.id
    assert Repo.aggregate(Target, :count) == 2
  end

  test "a malformed expected-current-target is refused rather than ignored" do
    operator = operator_fixture("promotion-bad-precondition")
    sha = seeded_commit(@repo)

    assert {:error, :invalid_expected_target} =
             Promotion.promote(operator, attrs(sha, %{"expected_current_target_id" => "newest"}))
  end

  test "every attempt leaves bounded audit evidence and no plaintext key" do
    operator = operator_fixture("promotion-audit")
    ordinary = promotion_user_fixture("promotion-audit-ordinary")
    sha = seeded_commit(@repo)
    key = "release-audit-0001"

    assert {:ok, %{target: target}} =
             Promotion.promote(operator, attrs(sha, %{"idempotency_key" => key}))

    assert {:error, :not_operator} = Promotion.promote(ordinary, attrs(sha))

    promoted = event!("forge.fleet_target.promoted")
    assert promoted.subject_id == target.id
    assert promoted.actor_type == "operator"
    assert promoted.actor_id == operator.id
    assert promoted.metadata["repo"] == @repo
    assert promoted.metadata["environment"] == "production"
    assert promoted.metadata["source"] == "api"
    assert promoted.metadata["idempotency_key_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    refute Jason.encode!(promoted.metadata) =~ key

    refused = event!("forge.fleet_target.promotion_refused")
    assert refused.metadata["reason"] == "not_operator"
  end

  defp event!(type) do
    AuditEvent
    |> Ecto.Query.where([event], event.event_type == ^type)
    |> Ecto.Query.order_by([event], desc: event.inserted_at)
    |> Ecto.Query.limit(1)
    |> Repo.one()
    |> case do
      nil -> flunk("no #{type} audit event was recorded")
      event -> event
    end
  end
end
