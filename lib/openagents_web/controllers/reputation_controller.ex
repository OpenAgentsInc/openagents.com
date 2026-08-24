defmodule OpenAgentsWeb.ReputationController do
  @moduledoc """
  Reputation attestations for accepted outcomes, published forge first.

  Every response carries the signed claim verbatim next to its signature and
  the admitted issuer key, so a client can canonicalize the claim, check the
  Ed25519 signature, compare the verifier policy, resolve the evidence, and
  read the revocation state without trusting this API or the web interface.
  Disclosure follows the repository: a reader outside the repository sees
  `public` attestations only.

  An attestation names its subject with a bare string. The subject-claim
  actions here are how an account establishes which strings are its own — it
  asks, and an operator decides — so that an account-scoped read such as
  `GET /data/export/account` has a filter that resolves rather than guesses.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Accounts
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

  ## Subject claims

  @doc "Records this account's claim on an attestation subject."
  def create_subject_claim(conn, %{"subject_kind" => kind, "subject_id" => subject_id} = params)
      when is_binary(kind) and is_binary(subject_id) do
    attributes = %{
      "subject_kind" => kind,
      "subject_id" => String.trim(subject_id),
      "forum_actor_link_id" => params["forum_actor_link_id"],
      "agent_id" => params["agent_id"],
      "proof_method" => params["proof_method"] || "api_token"
    }

    case Reputation.claim_subject(conn.assigns.current_user, attributes) do
      {:ok, claim} ->
        conn
        |> put_status(:created)
        |> json(Reputation.subject_claim_projection(claim))

      {:error, %Ecto.Changeset{} = changeset} ->
        unprocessable(conn, changeset_message(changeset))

      {:error, reason} ->
        unprocessable(conn, Atom.to_string(reason))
    end
  end

  def create_subject_claim(conn, _params),
    do: unprocessable(conn, "subject_kind and subject_id are required")

  @doc "Every subject claim this account made, at every status."
  def list_subject_claims(conn, _params) do
    claims = Reputation.list_subject_claims(conn.assigns.current_user)
    json(conn, %{"claims" => Enum.map(claims, &Reputation.subject_claim_projection/1)})
  end

  @doc "Every subject claim waiting on review. Operators only."
  def pending_subject_claims(conn, _params) do
    case ensure_operator(conn) do
      :ok ->
        claims = Reputation.list_pending_subject_claims()
        json(conn, %{"claims" => Enum.map(claims, &Reputation.subject_claim_projection/1)})

      {:error, :forbidden} ->
        forbidden(conn)
    end
  end

  @doc "Approves or rejects a pending subject claim. Operators only."
  def update_subject_claim(conn, %{"id" => id, "status" => status}) do
    with :ok <- ensure_operator(conn),
         {:ok, claim} <- Reputation.fetch_subject_claim(id),
         {:ok, claim} <- review_subject_claim(claim, status) do
      json(conn, Reputation.subject_claim_projection(claim))
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_status} -> unprocessable(conn, "status must be linked or rejected")
      {:error, :not_pending} -> conflict(conn, "claim_not_pending")
      {:error, %Ecto.Changeset{} = changeset} -> unprocessable(conn, changeset_message(changeset))
    end
  end

  def update_subject_claim(conn, _params),
    do: unprocessable(conn, "status must be linked or rejected")

  defp ensure_operator(conn) do
    if Accounts.admin?(conn.assigns[:current_user]), do: :ok, else: {:error, :forbidden}
  end

  defp review_subject_claim(claim, "linked"), do: Reputation.approve_subject_claim(claim)
  defp review_subject_claim(claim, "rejected"), do: Reputation.reject_subject_claim(claim)
  defp review_subject_claim(_claim, _status), do: {:error, :invalid_status}

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  defp unprocessable(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{"message" => message})

  defp conflict(conn, message),
    do: conn |> put_status(:conflict) |> json(%{"message" => message})

  defp forbidden(conn), do: conn |> put_status(:forbidden) |> json(%{"message" => "Forbidden"})

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
