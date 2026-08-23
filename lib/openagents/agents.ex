defmodule OpenAgents.Agents do
  @moduledoc """
  Self-registered agent accounts, credentials, and optional human links.

  Agent credentials are deliberately narrower than human API tokens. They can
  participate in public conversations, but they never inherit human membership
  or operator authority.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Agents.{Agent, AgentBoxGrant, AgentToken, AgentUserLink}
  alias OpenAgents.Audit
  alias OpenAgents.Repo

  @prefix "oa_agent_"
  @scope "agent:participate"
  @maximum_lifetime_days 365
  @default_lifetime_days 365
  @default_registration_window_seconds 3_600
  @default_registration_per_ip 3
  @default_registration_global 100

  @spec register(map()) ::
          {:ok, Agent.t(), String.t()} | {:error, Ecto.Changeset.t() | atom()}
  def register(attributes) when is_map(attributes) do
    with {:ok, handle} <- handle(attributes),
         {:ok, display_name} <- text(attributes, "display_name", 255),
         {:ok, description} <- optional_text(attributes, "description", 4_000),
         {:ok, ip_digest} <- registration_ip_digest(attributes),
         :ok <- registration_allowed?(ip_digest),
         :ok <- handle_available?(handle) do
      Repo.transaction(fn ->
        agent =
          %Agent{}
          |> Agent.changeset(%{
            handle: handle,
            display_name: display_name,
            description: description,
            registration_ip_digest: ip_digest
          })
          |> Repo.insert!()

        {:ok, _token, plaintext} = mint_credential(agent, %{name: "registration"})

        Audit.record!("agent.registered", {:agent, agent.id}, "agent", agent.id,
          metadata: %{"handle" => agent.handle}
        )

        {agent, plaintext}
      end)
      |> case do
        {:ok, {agent, plaintext}} -> {:ok, agent, plaintext}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def register(_attributes), do: {:error, :invalid_registration}

  @spec authenticate(String.t()) ::
          {:ok, Agent.t(), AgentToken.t()} | {:error, :invalid_agent_credential}
  def authenticate(@prefix <> rest = plaintext) when byte_size(plaintext) < 200 do
    result =
      Repo.transaction(fn ->
        with [id, secret] <- String.split(rest, ".", parts: 2),
             true <- byte_size(secret) in 40..64,
             {:ok, token_id} <- Ecto.UUID.cast(id),
             %AgentToken{} = token <-
               Repo.one(from t in AgentToken, where: t.id == ^token_id, lock: "FOR UPDATE"),
             true <- Plug.Crypto.secure_compare(token.token_digest, digest(plaintext)),
             true <- usable?(token),
             %Agent{status: "active"} = agent <- Repo.get(Agent, token.agent_id) do
          now = DateTime.utc_now()

          Repo.update_all(from(t in AgentToken, where: t.id == ^token.id),
            set: [last_used_at: now]
          )

          {agent, %{token | last_used_at: now}}
        else
          _invalid -> Repo.rollback(:invalid_agent_credential)
        end
      end)

    case result do
      {:ok, {agent, token}} -> {:ok, agent, token}
      {:error, _invalid} -> {:error, :invalid_agent_credential}
    end
  end

  def authenticate(_plaintext), do: {:error, :invalid_agent_credential}

  def authenticate(plaintext, @scope), do: authenticate(plaintext)
  def authenticate(_plaintext, _scope), do: {:error, :invalid_agent_credential}

  @spec mint_credential(Agent.t(), map()) ::
          {:ok, AgentToken.t(), String.t()} | {:error, Ecto.Changeset.t() | atom()}
  def mint_credential(agent, attributes \\ %{})

  def mint_credential(%Agent{status: "active", id: agent_id} = agent, attributes)
      when is_map(attributes) do
    with :ok <- ensure_active_agent(agent_id),
         {:ok, name} <- token_name(attributes),
         {:ok, lifetime_days} <- lifetime_days(attributes) do
      id = Ecto.UUID.generate()
      secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      plaintext = @prefix <> id <> "." <> secret

      token =
        %AgentToken{
          id: id,
          agent_id: agent_id,
          token_digest: digest(plaintext)
        }
        |> AgentToken.create_changeset(%{
          name: name,
          last_four: String.slice(secret, -4, 4),
          scopes: [@scope],
          expires_at: DateTime.add(DateTime.utc_now(), lifetime_days, :day)
        })
        |> Repo.insert()

      case token do
        {:ok, token} ->
          Audit.record!("agent.credential_minted", {:agent, agent.id}, "agent_token", token.id,
            metadata: %{"scopes" => [@scope]}
          )

          {:ok, token, plaintext}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def mint_credential(%Agent{}, _attributes), do: {:error, :agent_suspended}

  defp ensure_active_agent(agent_id) do
    if Repo.exists?(from a in Agent, where: a.id == ^agent_id and a.status == "active") do
      :ok
    else
      {:error, :agent_suspended}
    end
  end

  def suspend(%Agent{} = agent, reason) when is_binary(reason) do
    now = DateTime.utc_now()

    agent
    |> Ecto.Changeset.change(status: "suspended", suspended_at: now, suspension_reason: reason)
    |> Repo.update()
    |> case do
      {:ok, suspended} ->
        Audit.record!("agent.suspended", {:agent, agent.id}, "agent", agent.id,
          metadata: %{"reason" => reason}
        )

        {:ok, suspended}

      error ->
        error
    end
  end

  def suspend(%Agent{}, _reason), do: {:error, :invalid_suspension_reason}

  def reinstate(%Agent{} = agent) do
    agent
    |> Ecto.Changeset.change(status: "active", suspended_at: nil, suspension_reason: nil)
    |> Repo.update()
    |> case do
      {:ok, reinstated} ->
        Audit.record!("agent.reinstated", {:agent, agent.id}, "agent", agent.id)
        {:ok, reinstated}

      error ->
        error
    end
  end

  def get_by_handle(handle) when is_binary(handle) do
    Repo.get_by(Agent, handle: String.downcase(handle))
  end

  def get_by_handle!(handle) when is_binary(handle) do
    Repo.get_by!(Agent, handle: String.downcase(handle))
  end

  def list_links(%Agent{id: agent_id}) do
    Repo.all(
      from link in AgentUserLink,
        where: link.agent_id == ^agent_id,
        order_by: [desc: link.inserted_at],
        preload: [:user]
    )
  end

  def list_pending_links(%User{id: user_id}) do
    Repo.all(
      from link in AgentUserLink,
        where: link.user_id == ^user_id and link.status == "pending",
        order_by: [asc: link.inserted_at],
        preload: [:agent]
    )
  end

  def request_link(%Agent{id: agent_id} = agent, %User{id: user_id}) do
    attrs = %{
      agent_id: agent_id,
      user_id: user_id,
      status: "pending",
      proof_method: "agent_credential",
      proof_evidence: %{"requested_at" => DateTime.to_iso8601(DateTime.utc_now())},
      linked_at: nil,
      rejected_at: nil
    }

    result =
      case Repo.get_by(AgentUserLink, agent_id: agent_id, user_id: user_id) do
        nil ->
          %AgentUserLink{} |> AgentUserLink.changeset(attrs) |> Repo.insert()

        %AgentUserLink{status: status} = link when status in ["rejected", "unlinked"] ->
          link |> AgentUserLink.changeset(attrs) |> Repo.update()

        _linked_or_pending ->
          {:error, :link_already_active}
      end

    audit_link(result, "agent.link_requested", {:agent, agent.id})
  end

  def accept_link(%User{id: user_id}, id) do
    with {:ok, link} <- fetch_link(id),
         true <- link.user_id == user_id,
         "pending" <- link.status do
      link
      |> AgentUserLink.changeset(%{
        status: "linked",
        linked_at: DateTime.utc_now(),
        proof_evidence:
          Map.put(
            link.proof_evidence || %{},
            "accepted_at",
            DateTime.to_iso8601(DateTime.utc_now())
          )
      })
      |> Repo.update()
      |> audit_link("agent.link_accepted", {:user, user_id})
    else
      _ -> {:error, :link_not_found}
    end
  end

  def reject_link(%User{id: user_id}, id) do
    with {:ok, link} <- fetch_link(id),
         true <- link.user_id == user_id,
         "pending" <- link.status do
      link
      |> AgentUserLink.changeset(%{
        status: "rejected",
        rejected_at: DateTime.utc_now()
      })
      |> Repo.update()
      |> audit_link("agent.link_rejected", {:user, user_id})
    else
      _ -> {:error, :link_not_found}
    end
  end

  def unlink(%Agent{id: agent_id} = agent, %User{id: user_id}) do
    with %AgentUserLink{} = link <-
           Repo.one(
             from l in AgentUserLink,
               where: l.agent_id == ^agent_id and l.user_id == ^user_id and l.status == "linked",
               preload: [:agent]
           ) do
      link
      |> AgentUserLink.changeset(%{
        status: "unlinked",
        linked_at: nil,
        rejected_at: nil
      })
      |> Repo.update()
      |> audit_link("agent.link_unlinked", {:agent, agent.id})
    else
      _ -> {:error, :link_not_found}
    end
  end

  def unlink(%User{id: user_id}, id) do
    with {:ok, link} <- fetch_link(id),
         true <- link.user_id == user_id,
         "linked" <- link.status do
      link
      |> AgentUserLink.changeset(%{
        status: "unlinked",
        linked_at: nil,
        rejected_at: nil
      })
      |> Repo.update()
      |> audit_link("agent.link_unlinked", {:user, user_id})
    else
      _ -> {:error, :link_not_found}
    end
  end

  @doc "Grants a linked agent revocable Box control."
  @spec grant_box_control(User.t(), Agent.t()) ::
          {:ok, AgentBoxGrant.t()} | {:error, atom()}
  def grant_box_control(%User{} = user, %Agent{} = agent),
    do: grant_control(user, agent, "box")

  @doc "Grants a linked agent revocable Computer control."
  @spec grant_computer_control(User.t(), Agent.t()) ::
          {:ok, AgentBoxGrant.t()} | {:error, atom()}
  def grant_computer_control(%User{} = user, %Agent{} = agent),
    do: grant_control(user, agent, "computer")

  @doc "Grants a linked agent one explicit control target."
  @spec grant_control(User.t(), Agent.t(), String.t()) ::
          {:ok, AgentBoxGrant.t()} | {:error, atom()}
  def grant_control(%User{id: user_id}, %Agent{id: agent_id}, target_kind)
      when target_kind in ["box", "computer"] do
    with true <- linked?(agent_id, user_id) do
      scope = if target_kind == "box", do: "box:control", else: "computer:control"

      %AgentBoxGrant{}
      |> AgentBoxGrant.changeset(%{
        agent_id: agent_id,
        user_id: user_id,
        granted_by_id: user_id,
        target_kind: target_kind,
        scope: scope,
        granted_at: DateTime.utc_now()
      })
      |> Repo.insert()
    else
      _ -> {:error, :agent_not_linked}
    end
  end

  @doc "Revokes an agent's active Box-control grant."
  @spec revoke_box_control(User.t(), Agent.t()) :: {:ok, AgentBoxGrant.t()} | {:error, atom()}
  def revoke_box_control(%User{} = user, %Agent{} = agent),
    do: revoke_control(user, agent, "box")

  @doc "Revokes an agent's active Computer-control grant."
  @spec revoke_computer_control(User.t(), Agent.t()) ::
          {:ok, AgentBoxGrant.t()} | {:error, atom()}
  def revoke_computer_control(%User{} = user, %Agent{} = agent),
    do: revoke_control(user, agent, "computer")

  @doc "Revokes an agent's active grant for one explicit control target."
  @spec revoke_control(User.t(), Agent.t(), String.t()) ::
          {:ok, AgentBoxGrant.t()} | {:error, atom()}
  def revoke_control(%User{id: user_id}, %Agent{id: agent_id}, target_kind)
      when target_kind in ["box", "computer"] do
    scope = if target_kind == "box", do: "box:control", else: "computer:control"

    case Repo.one(
           from grant in AgentBoxGrant,
             where:
               grant.agent_id == ^agent_id and grant.user_id == ^user_id and
                 grant.target_kind == ^target_kind and grant.scope == ^scope and
                 is_nil(grant.revoked_at)
         ) do
      %AgentBoxGrant{} = grant ->
        grant |> AgentBoxGrant.changeset(%{revoked_at: DateTime.utc_now()}) |> Repo.update()

      nil ->
        {:error, :grant_not_found}
    end
  end

  @doc "Checks whether a linked agent has an active Box-control grant."
  @spec box_control_granted?(Agent.t()) :: boolean()
  def box_control_granted?(%Agent{id: agent_id}) do
    control_granted?(%Agent{id: agent_id}, "box")
  end

  @doc "Checks whether a linked agent has an active Computer-control grant."
  @spec computer_control_granted?(Agent.t()) :: boolean()
  def computer_control_granted?(%Agent{id: agent_id}) do
    control_granted?(%Agent{id: agent_id}, "computer")
  end

  @doc "Checks whether a linked agent has an active grant for a target kind."
  @spec control_granted?(Agent.t(), String.t()) :: boolean()
  def control_granted?(%Agent{id: agent_id}, target_kind)
      when target_kind in ["box", "computer"] do
    scope = if target_kind == "box", do: "box:control", else: "computer:control"

    Repo.exists?(
      from grant in AgentBoxGrant,
        where:
          grant.agent_id == ^agent_id and grant.target_kind == ^target_kind and
            grant.scope == ^scope and is_nil(grant.revoked_at),
        join: link in AgentUserLink,
        on:
          link.agent_id == grant.agent_id and link.user_id == grant.user_id and
            link.status == "linked"
    )
  end

  @doc "Returns the human account that currently grants an agent Box control."
  @spec box_control_owner(Agent.t()) :: User.t() | nil
  def box_control_owner(%Agent{id: agent_id}) do
    control_owner(%Agent{id: agent_id}, "box")
  end

  @doc "Returns the human account that currently grants an agent Computer control."
  @spec computer_control_owner(Agent.t()) :: User.t() | nil
  def computer_control_owner(%Agent{id: agent_id}) do
    control_owner(%Agent{id: agent_id}, "computer")
  end

  @doc "Returns the linked human account granting an agent a target kind."
  @spec control_owner(Agent.t(), String.t()) :: User.t() | nil
  def control_owner(%Agent{id: agent_id}, target_kind)
      when target_kind in ["box", "computer"] do
    scope = if target_kind == "box", do: "box:control", else: "computer:control"

    Repo.one(
      from grant in AgentBoxGrant,
        join: link in AgentUserLink,
        on:
          link.agent_id == grant.agent_id and link.user_id == grant.user_id and
            link.status == "linked",
        join: user in User,
        on: user.id == grant.user_id,
        where:
          grant.agent_id == ^agent_id and grant.target_kind == ^target_kind and
            grant.scope == ^scope and is_nil(grant.revoked_at),
        select: user
    )
  end

  defp linked?(agent_id, user_id) do
    Repo.exists?(
      from link in AgentUserLink,
        where: link.agent_id == ^agent_id and link.user_id == ^user_id and link.status == "linked"
    )
  end

  defp fetch_link(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %AgentUserLink{} = link <- Repo.get(AgentUserLink, uuid) do
      {:ok, Repo.preload(link, [:agent, :user])}
    else
      _ -> {:error, :link_not_found}
    end
  end

  defp audit_link({:ok, link}, event, actor) do
    Audit.record!(event, actor, "agent_user_link", link.id)
    {:ok, link}
  end

  defp audit_link({:error, _} = error, _event, _agent), do: error

  defp handle(attributes) do
    case attributes |> Map.get("handle", Map.get(attributes, :handle)) |> normalize_handle() do
      {:ok, handle} -> {:ok, handle}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_handle(value) when is_binary(value) do
    handle = String.downcase(String.trim(value))

    cond do
      byte_size(handle) not in 3..39 -> {:error, :invalid_handle}
      handle =~ ~r/\A\d+\z/ -> {:error, :confusable_handle}
      handle =~ ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ -> {:ok, handle}
      true -> {:error, :confusable_handle}
    end
  end

  defp normalize_handle(_value), do: {:error, :invalid_handle}

  defp handle_available?(handle) do
    reserved? = handle in OpenAgents.Repositories.Namespace.reserved_slugs()

    user_taken? =
      Repo.exists?(from u in User, where: fragment("lower(?)", u.github_login) == ^handle)

    agent_taken? = Repo.exists?(from a in Agent, where: fragment("lower(?)", a.handle) == ^handle)

    if reserved? or user_taken? or agent_taken?, do: {:error, :handle_taken}, else: :ok
  end

  defp registration_ip_digest(attributes) do
    case Map.get(attributes, "registration_ip") || Map.get(attributes, :registration_ip) do
      ip when is_binary(ip) and ip != "" -> {:ok, digest(ip)}
      _ -> {:error, :registration_ip_required}
    end
  end

  defp registration_allowed?(ip_digest) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -registration_window_seconds(), :second)

    ip_count =
      Repo.aggregate(
        from(a in Agent,
          where: a.registration_ip_digest == ^ip_digest and a.inserted_at >= ^cutoff
        ),
        :count
      )

    global_count = Repo.aggregate(from(a in Agent, where: a.inserted_at >= ^cutoff), :count)

    if ip_count >= registration_per_ip() or global_count >= registration_global() do
      {:error, {:rate_limited, registration_window_seconds()}}
    else
      :ok
    end
  end

  defp text(attributes, key, maximum) do
    case attribute(attributes, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" ->
            {:error, :invalid_registration}

          text ->
            if String.length(text) <= maximum do
              {:ok, text}
            else
              {:error, :"#{key}_too_long"}
            end
        end

      _ ->
        {:error, :invalid_registration}
    end
  end

  defp optional_text(attributes, key, maximum) do
    case attribute(attributes, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        text = String.trim(value)
        if String.length(text) <= maximum, do: {:ok, text}, else: {:error, :"#{key}_too_long"}

      _ ->
        {:error, :invalid_registration}
    end
  end

  defp token_name(attributes) do
    case attribute(attributes, "name") || "agent credential" do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, String.slice(value, 0, 80)}
      _ -> {:error, :invalid_agent_credential}
    end
  end

  defp lifetime_days(attributes) do
    case attribute(attributes, "lifetime_days") || @default_lifetime_days do
      days when is_integer(days) and days in 1..@maximum_lifetime_days ->
        {:ok, days}

      days when is_binary(days) ->
        case Integer.parse(days) do
          {number, ""} when number in 1..@maximum_lifetime_days -> {:ok, number}
          _ -> {:error, :invalid_agent_credential}
        end

      _ ->
        {:error, :invalid_agent_credential}
    end
  end

  defp usable?(token) do
    is_nil(token.revoked_at) and @scope in token.scopes and
      DateTime.compare(DateTime.utc_now(), token.expires_at) == :lt
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp attribute(attributes, "display_name"),
    do: Map.get(attributes, "display_name") || Map.get(attributes, :display_name)

  defp attribute(attributes, "description"),
    do: Map.get(attributes, "description") || Map.get(attributes, :description)

  defp attribute(attributes, "name"),
    do: Map.get(attributes, "name") || Map.get(attributes, :name)

  defp attribute(attributes, "lifetime_days"),
    do: Map.get(attributes, "lifetime_days") || Map.get(attributes, :lifetime_days)

  defp registration_window_seconds,
    do:
      Application.get_env(
        :openagents,
        :agent_registration_window_seconds,
        @default_registration_window_seconds
      )

  defp registration_per_ip,
    do: Application.get_env(:openagents, :agent_registration_per_ip, @default_registration_per_ip)

  defp registration_global,
    do: Application.get_env(:openagents, :agent_registration_global, @default_registration_global)
end
