defmodule OpenAgentsWeb.AgentController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.Accounts
  alias OpenAgents.Agents
  alias OpenAgents.Agents.{Agent, AgentUserLink}
  alias OpenAgents.Repo

  def register(conn, params) do
    attributes = Map.put(params, "registration_ip", remote_ip(conn))

    case Agents.register(attributes) do
      {:ok, agent, credential} ->
        conn
        |> put_status(:created)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          "agent" => profile(agent),
          "token" => credential,
          "warning" => "This credential is shown once. Store it securely."
        })

      {:error, {:rate_limited, window}} ->
        refusal(conn, :too_many_requests, "registration_rate_limited", %{
          "window_seconds" => window
        })

      {:error, reason} ->
        refusal(conn, :unprocessable_entity, error_code(reason))
    end
  end

  def show(conn, %{"handle" => handle}) do
    case Agents.get_by_handle(handle) do
      %Agent{} = agent -> json(conn, %{"agent" => profile(agent)})
      nil -> refusal(conn, :not_found, "agent_not_found")
    end
  end

  def current(conn, _params) do
    json(conn, %{
      "agent" => profile(conn.assigns.current_agent),
      "credential" => credential_projection(conn.assigns[:agent_token]),
      "links" => Enum.map(Agents.list_links(conn.assigns.current_agent), &link_json/1)
    })
  end

  def rotate_credential(conn, params) do
    case Agents.mint_credential(conn.assigns.current_agent, params) do
      {:ok, token, credential} ->
        conn
        |> put_status(:created)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          "credential" => credential,
          "token" => credential_projection(token),
          "warning" => "This credential is shown once. Store it securely."
        })

      {:error, reason} ->
        refusal(conn, :unprocessable_entity, error_code(reason))
    end
  end

  def request_link(conn, %{"user_id" => user_id}) do
    with {:ok, user} <- Accounts.get_active_user(user_id),
         {:ok, link} <- Agents.request_link(conn.assigns.current_agent, user) do
      conn |> put_status(:created) |> json(%{"link" => link_json(link)})
    else
      {:error, :banned} ->
        refusal(conn, :forbidden, "user_unavailable")

      {:error, :not_found} ->
        refusal(conn, :not_found, "user_not_found")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{"errors" => errors(changeset)})
    end
  end

  def request_link(conn, _params), do: refusal(conn, :unprocessable_entity, "user_id_required")

  def links(conn, _params) do
    json(conn, %{
      "links" => Enum.map(Agents.list_pending_links(conn.assigns.current_user), &link_json/1)
    })
  end

  def accept_link(conn, %{"id" => id}), do: review_link(conn, id, :accept)
  def reject_link(conn, %{"id" => id}), do: review_link(conn, id, :reject)
  def unlink(conn, %{"id" => id}), do: review_link(conn, id, :unlink)

  def grant_box_control(conn, %{"handle" => handle}) do
    with %Agent{} = agent <- Agents.get_by_handle(handle),
         {:ok, grant} <- Agents.grant_box_control(conn.assigns.current_user, agent) do
      json(conn, %{"grant" => grant_json(grant)})
    else
      nil -> refusal(conn, :not_found, "agent_not_found")
      {:error, reason} -> refusal(conn, :conflict, error_code(reason))
    end
  end

  def revoke_box_control(conn, %{"handle" => handle}) do
    with %Agent{} = agent <- Agents.get_by_handle(handle),
         {:ok, grant} <- Agents.revoke_box_control(conn.assigns.current_user, agent) do
      json(conn, %{"grant" => grant_json(grant)})
    else
      nil -> refusal(conn, :not_found, "agent_not_found")
      {:error, reason} -> refusal(conn, :conflict, error_code(reason))
    end
  end

  def grant_computer_control(conn, %{"handle" => handle}) do
    with %Agent{} = agent <- Agents.get_by_handle(handle),
         {:ok, grant} <- Agents.grant_computer_control(conn.assigns.current_user, agent) do
      json(conn, %{"grant" => grant_json(grant)})
    else
      nil -> refusal(conn, :not_found, "agent_not_found")
      {:error, reason} -> refusal(conn, :conflict, error_code(reason))
    end
  end

  def revoke_computer_control(conn, %{"handle" => handle}) do
    with %Agent{} = agent <- Agents.get_by_handle(handle),
         {:ok, grant} <- Agents.revoke_computer_control(conn.assigns.current_user, agent) do
      json(conn, %{"grant" => grant_json(grant)})
    else
      nil -> refusal(conn, :not_found, "agent_not_found")
      {:error, reason} -> refusal(conn, :conflict, error_code(reason))
    end
  end

  def suspend(conn, %{"handle" => handle} = params) do
    with %Agent{} = agent <- Agents.get_by_handle(handle),
         {:ok, suspended} <- Agents.suspend(agent, params["reason"] || "operator suspension") do
      json(conn, %{"agent" => profile(suspended)})
    else
      nil -> refusal(conn, :not_found, "agent_not_found")
      {:error, reason} -> refusal(conn, :unprocessable_entity, error_code(reason))
    end
  end

  def reinstate(conn, %{"handle" => handle}) do
    with %Agent{} = agent <- Agents.get_by_handle(handle),
         {:ok, reinstated} <- Agents.reinstate(agent) do
      json(conn, %{"agent" => profile(reinstated)})
    else
      nil -> refusal(conn, :not_found, "agent_not_found")
      {:error, reason} -> refusal(conn, :unprocessable_entity, error_code(reason))
    end
  end

  defp review_link(conn, id, action) do
    result =
      case action do
        :accept -> Agents.accept_link(conn.assigns.current_user, id)
        :reject -> Agents.reject_link(conn.assigns.current_user, id)
        :unlink -> Agents.unlink(conn.assigns.current_user, id)
      end

    case result do
      {:ok, link} -> json(conn, %{"link" => link_json(Repo.preload(link, [:agent, :user]))})
      {:error, :link_not_found} -> refusal(conn, :not_found, "link_not_found")
      {:error, reason} -> refusal(conn, :conflict, error_code(reason))
    end
  end

  defp profile(%Agent{} = agent) do
    %{
      "id" => agent.id,
      "handle" => agent.handle,
      "display_name" => agent.display_name,
      "description" => agent.description,
      "status" => agent.status
    }
  end

  defp credential_projection(nil), do: nil

  defp credential_projection(token) do
    %{
      "id" => token.id,
      "name" => token.name,
      "last_four" => token.last_four,
      "scopes" => token.scopes,
      "expires_at" => DateTime.to_iso8601(token.expires_at),
      "last_used_at" => token.last_used_at,
      "revoked_at" => token.revoked_at
    }
  end

  defp link_json(%AgentUserLink{} = link) do
    %{
      "id" => link.id,
      "agent_id" => link.agent_id,
      "user_id" => link.user_id,
      "status" => link.status,
      "proof_method" => link.proof_method,
      "linked_at" => link.linked_at,
      "rejected_at" => link.rejected_at
    }
  end

  defp grant_json(grant) do
    %{
      "id" => grant.id,
      "agent_id" => grant.agent_id,
      "user_id" => grant.user_id,
      "granted_by_id" => grant.granted_by_id,
      "target_kind" => grant.target_kind,
      "scope" => grant.scope,
      "granted_at" => grant.granted_at,
      "revoked_at" => grant.revoked_at
    }
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp errors(changeset), do: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)

  defp translate_error({message, options}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      to_string(Keyword.get(options, String.to_existing_atom(key), key))
    end)
  end

  defp error_code(:invalid_handle), do: "invalid_handle"
  defp error_code(:confusable_handle), do: "confusable_handle"
  defp error_code(:handle_taken), do: "handle_unavailable"
  defp error_code(:registration_ip_required), do: "registration_unavailable"
  defp error_code(:agent_suspended), do: "agent_suspended"
  defp error_code(:display_name_too_long), do: "display_name_too_long"
  defp error_code(:description_too_long), do: "description_too_long"
  defp error_code(:link_already_active), do: "link_already_active"
  defp error_code(:invalid_registration), do: "invalid_registration"
  defp error_code(:invalid_agent_credential), do: "invalid_agent_credential"
  defp error_code(:link_not_found), do: "link_not_found"
  defp error_code(:user_unavailable), do: "user_unavailable"
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "request_refused"

  defp refusal(conn, status, code, details \\ %{}) do
    body = Map.merge(%{"error" => %{"code" => code}}, details)
    conn |> put_status(status) |> json(body)
  end
end
