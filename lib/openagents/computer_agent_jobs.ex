defmodule OpenAgents.ComputerAgentJobs do
  @moduledoc """
  Owner-scoped entry point for durable ACP coding-agent delegations.

  Both the `computer_agent` model tool and the signed-in Computers API enter
  here so ownership, presence, probe evidence, cwd scope, and durable job
  construction cannot drift between surfaces.
  """

  alias OpenAgents.Accounts.User
  alias OpenAgents.Computer
  alias OpenAgents.Conversations.{Conversation, Visitor}
  alias OpenAgents.Machines.Machine
  alias OpenAgents.{Repo, Work}

  @delegation_timeout_ms 3_600_000

  def start(user, machine, conversation, params, opts \\ [])

  def start(
        %User{} = user,
        %Machine{} = machine,
        %Conversation{} = conversation,
        params,
        opts
      )
      when is_map(params) do
    agent_id = params["agent_id"]
    prompt = params["prompt"]
    cwd = normalize_path(params["cwd"])
    resume_session_id = bounded_optional(params["resume_session_id"], 128)
    surface = if Keyword.get(opts, :surface) == "voice", do: "voice", else: "text"

    with :ok <- verify_enabled(),
         :ok <- validate_owner(user, machine, conversation),
         :ok <- validate_machine(machine),
         :ok <- validate_agent(machine, agent_id),
         :ok <- validate_prompt(prompt),
         :ok <- validate_cwd(machine.roots, cwd) do
      owner = Repo.get!(Visitor, conversation.visitor_id)

      delegation =
        %{
          "agent_id" => agent_id,
          "machine_id" => machine.id,
          "machine_name" => machine.name,
          "prompt" => prompt,
          "timeout_ms" => @delegation_timeout_ms,
          "cwd" => cwd
        }
        |> put_optional("resume_session_id", resume_session_id)

      attributes = %{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: surface,
        goal: String.slice("Delegate to #{agent_id} on #{machine.name}: #{prompt}", 0, 2_000),
        delegation: delegation
      }

      Work.start_delegation(attributes)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def start(%User{}, %Machine{}, %Conversation{}, _params, _opts),
    do: {:error, :invalid_delegation_request}

  defp verify_enabled do
    if Computer.enabled?(), do: :ok, else: {:error, :computer_controller_disabled}
  end

  defp validate_owner(
         %User{id: user_id},
         %Machine{user_id: user_id},
         %Conversation{visitor_id: visitor_id}
       ) do
    case Repo.get(Visitor, visitor_id) do
      %Visitor{user_id: ^user_id} -> :ok
      _other -> {:error, :conversation_not_found}
    end
  end

  defp validate_owner(_user, _machine, _conversation), do: {:error, :machine_not_found}

  defp validate_machine(%Machine{status: "active", id: machine_id}) do
    if Computer.online?(machine_id), do: :ok, else: {:error, :machine_offline}
  end

  defp validate_machine(%Machine{}), do: {:error, :machine_revoked}

  defp validate_agent(%Machine{last_probe: %{"acp_agents" => agents}}, agent_id)
       when is_list(agents) and is_binary(agent_id) and byte_size(agent_id) <= 64 do
    if String.trim(agent_id) != "" and
         Enum.any?(agents, &(is_map(&1) and &1["id"] == agent_id)) do
      :ok
    else
      {:error, :agent_not_available}
    end
  end

  defp validate_agent(%Machine{}, agent_id) when is_binary(agent_id),
    do: {:error, :agent_not_available}

  defp validate_agent(%Machine{}, _agent_id), do: {:error, :invalid_delegation_request}

  defp validate_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) != "" and byte_size(prompt) <= 8_000,
      do: :ok,
      else: {:error, :invalid_delegation_request}
  end

  defp validate_prompt(_prompt), do: {:error, :invalid_delegation_request}

  defp validate_cwd(roots, cwd) when is_list(roots) and is_binary(cwd) and cwd != "" do
    if path_without_parent?(cwd) and Enum.any?(roots, &inside_root?(cwd, &1)),
      do: :ok,
      else: {:error, :cwd_not_allowed}
  end

  defp validate_cwd(_roots, _cwd), do: {:error, :cwd_not_allowed}

  defp inside_root?(cwd, root) when is_binary(root) do
    normalized_root = normalize_path(root)

    normalized_root != "" and path_without_parent?(normalized_root) and
      (path_equal?(cwd, normalized_root) or
         String.starts_with?(path_compare(cwd), path_compare(normalized_root) <> "/"))
  end

  defp inside_root?(_cwd, _root), do: false

  defp path_without_parent?(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.all?(&(&1 not in [".", ".."]))
  end

  defp path_equal?(left, right), do: path_compare(left) == path_compare(right)

  defp path_compare(<<drive, ?:, _rest::binary>> = path)
       when drive in ?A..?Z or drive in ?a..?z,
       do: String.downcase(path)

  defp path_compare(path), do: path

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> String.slice(0, 500)
  end

  defp normalize_path(_path), do: ""

  defp bounded_optional(value, maximum) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, maximum)
    end
  end

  defp bounded_optional(_value, _maximum), do: nil

  defp put_optional(payload, _key, nil), do: payload
  defp put_optional(payload, key, value), do: Map.put(payload, key, value)
end
