defmodule OpenAgentsWeb.ReputationController do
  @moduledoc """
  Reputation attestations for accepted outcomes, published forge first.

  Every response carries the signed claim verbatim next to its signature and
  the admitted issuer key, so a client can canonicalize the claim, check the
  Ed25519 signature, compare the verifier policy, resolve the evidence, and
  read the revocation state without trusting this API or the web interface.
  Disclosure follows the repository: a reader outside the repository sees
  `public` attestations only.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Reputation
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ControllerHelpers

  def policy(conn, _params) do
    json(conn, %{
      "policy_id" => Reputation.policy_id(),
      "versions" => Enum.map(Reputation.policies(), &Reputation.policy_projection/1),
      "score" => nil
    })
  end

  def keys(conn, _params) do
    json(conn, %{"keys" => Enum.map(Reputation.keys(), &Reputation.key_projection/1)})
  end

  def index(conn, %{"owner" => owner, "repo" => repo, "issue_number" => issue_number}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])
    number = ControllerHelpers.integer_param!(issue_number)
    attestations = Reputation.list_for_issue(repository, number, tiers(conn, repository))

    json(conn, %{
      "repository" => "#{repository.owner}/#{repository.name}",
      "issue_number" => number,
      "attestations" => Enum.map(attestations, &Reputation.projection/1)
    })
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    case Reputation.get(repository, id, tiers(conn, repository)) do
      nil -> not_found(conn)
      attestation -> json(conn, Reputation.projection(attestation))
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def verification(conn, %{"owner" => owner, "repo" => repo, "id" => id} = params) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    case Reputation.get(repository, id, tiers(conn, repository)) do
      nil -> not_found(conn)
      attestation -> json(conn, Reputation.verify(attestation, expectation(params)))
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def subject(conn, %{"owner" => owner, "repo" => repo, "subject_id" => subject_id}) do
    repository = Repositories.get_visible_by_path!(owner, repo, conn.assigns[:current_user])

    json(conn, Reputation.subject_evidence(subject_id, repository))
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  # What the caller believes it is looking at. A mismatch is reported rather
  # than corrected, which is how a replayed attestation fails for a client
  # that names the issue, revision, subject, or verifier it expects.
  defp expectation(params) do
    %{
      subject_id: params["subject_id"],
      revision: params["revision"],
      event_type: params["event_type"],
      policy_id: params["policy_id"]
    }
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp tiers(conn, repository) do
    if Repositories.member?(repository, conn.assigns[:current_user]) do
      ~w(public repository private)
    else
      ~w(public)
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{message: "Not Found"})
end
