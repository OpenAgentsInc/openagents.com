defmodule OpenAgents.Tools.ComputerAgent do
  @moduledoc """
  Delegates a coding task to a named ACP agent on a paired computer.

  The controller speaks the Agent Client Protocol (ACP v1) to a local agent
  subprocess it launched by id: it negotiates the protocol version, opens a
  session in a folder the user shared, sends the prompt, streams the agent's
  progress back, and answers the agent's permission requests from the
  computer's own policy tier. Nothing here can widen what that tier permits,
  and the subprocess is killed on cancellation, timeout, or disconnection.

  The `agent_id` must appear in the computer's last committed probe report
  (`acp_agents`), so delegation targets come from committed facts rather than
  guesses. Supersedes `computer_devin.v1`, which hard-coded one agent.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Accounts.User
  alias OpenAgents.{ComputerAgentJobs, Conversations, Machines, Work}
  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Machines.Machine
  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, OwnerContext, Tool}

  # The turn is no longer held, so this is the ACP job's own wall — long enough
  # to edit, test, and commit. Cancel (#110) is how a person stops it early.
  @maximum_listed_agents 16

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.computer_agent.v1",
      name: "computer_agent",
      version: 1,
      description:
        "Starts a coding task on a named agent (claude, codex, gemini, devin) on a paired " <>
          "computer, over the Agent Client Protocol. It runs as a durable BACKGROUND job: " <>
          "this returns immediately with a job_id and status 'started' — acknowledge briefly " <>
          "and do NOT wait; several delegations run at once, each streams in the live panel " <>
          "and posts its result back into the conversation when done. agent_id must be in " <>
          "the computer's last computer_probe acp_agents inventory (run computer_probe first); " <>
          "honor the person's agent choice, else prefer one whose auth_ready is true. If " <>
          "starting is refused, report it and try a different agent or ask. machine_id comes " <>
          "from computer_list; omit only when exactly one computer is paired. cwd must be " <>
          "the project path (not the pairing root). Name it in the argument or prompt. " <>
          "Prefer resume_session_id from the last job in this conversation with the " <>
          "same cwd and agent after a timeout or cancel; start fresh after a cwd change. " <>
          "Supersedes computer_devin.",
      input_schema: input_schema(),
      output_schema: output_schema(),
      side_effect: :external_effect,
      required_scope: "browser_conversation",
      required_authority: "computer.control",
      executor: %{
        id: "sarah.computer.controller.acp",
        disclosure:
          "A named coding agent on the user's paired computer, over the Agent Client Protocol"
      },
      maintainer: "OpenAgents",
      attribution: [
        "OpenAgentsInc/openagents.com",
        "OpenAgentsInc/sarah-computer-controller",
        "agentclientprotocol/agent-client-protocol"
      ],
      policy_facets: %{
        "privacy" => "signed_browser_owner",
        "residency" => "operator_machine",
        "consent" => "machine_pairing"
      },
      module_metadata:
        Metadata.first_party("computer.control", "browser_conversation",
          effect: :external_effect,
          approval_class: "explicit_operator_approval",
          privacy: "signed_browser_owner",
          residency: "operator_machine"
        ),
      timeout_ms: 510_000,
      maximum_input_bytes: 16_384,
      maximum_output_bytes: 65_536,
      implementation: __MODULE__,
      tags: ~w(delegation delegate coding agent claude codex gemini devin machine computer)
    }
  end

  @impl true
  def execute(%{"agent_id" => agent_id, "prompt" => prompt} = arguments, context)
      when is_binary(agent_id) and is_binary(prompt) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_prompt(prompt),
         {:ok, user} <- OwnerContext.resolve(context),
         {:ok, machine} <- resolve_machine(user, arguments["machine_id"]) do
      case probed_agent_ids(machine) do
        {:ok, agent_ids} ->
          if agent_id in agent_ids do
            delegate(machine, agent_id, prompt, arguments, context)
          else
            {:ok, unknown_agent_refusal(machine, agent_id, arguments, agent_ids)}
          end

        :no_inventory ->
          {:ok, no_inventory_refusal(machine, agent_id, arguments)}
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_delegation_request}

  # Start the delegation as a durable background job and return immediately, so
  # the turn does not block and several delegations run at once. The job streams
  # to the live rail and posts its outcome as a report message when it finishes.
  defp delegate(machine, agent_id, prompt, arguments, context) do
    case resolve_cwd(arguments, prompt, context) do
      {:ok, cwd} ->
        start_job(machine, agent_id, prompt, arguments, context, cwd)

      :error ->
        {:ok, cwd_required_refusal(machine, agent_id, arguments)}
    end
  end

  defp start_job(machine, agent_id, prompt, arguments, context, cwd) do
    params =
      %{
        "agent_id" => agent_id,
        "prompt" => prompt,
        "cwd" => cwd
      }
      |> put_optional("resume_session_id", resolve_resume(arguments, context, cwd, agent_id))

    conversation = Conversations.get_conversation_for_user(%User{id: machine.user_id})
    user = %User{id: machine.user_id}

    case ComputerAgentJobs.start(user, machine, conversation, params,
           surface: job_surface(context)
         ) do
      {:ok, job} -> {:ok, started(machine, agent_id, arguments, job, cwd)}
      {:error, reason} -> {:ok, failure(machine, agent_id, arguments, reason)}
    end
  end

  defp job_surface(%{surface: "voice"}), do: "voice"
  defp job_surface(_context), do: "text"

  # The tool's own outcome: it succeeded at *starting* the delegation. The
  # delegation's result arrives later as the job's report message.
  defp started(machine, agent_id, arguments, job, cwd) do
    base(machine, agent_id, arguments, "started")
    |> put_in_result("status", "started")
    |> put_in_result("job_id", job.id)
    |> put_in_result("cwd", cwd)
    |> put_in_result(
      "resume_session_id",
      text(get_in(job.delegation || %{}, ["resume_session_id"]), 128)
    )
    |> put_in_result(
      "detail",
      "Delegation started in the background (job #{job.id}) in #{cwd}. It is streaming in " <>
        "the live panel and will report back into this conversation when it finishes. " <>
        "Acknowledge briefly and do not wait for it."
    )
  end

  defp validate_agent_id(agent_id) do
    if String.trim(agent_id) != "" and byte_size(agent_id) <= 64,
      do: :ok,
      else: {:error, :invalid_delegation_request}
  end

  defp validate_prompt(prompt) do
    trimmed = String.trim(prompt)

    if trimmed != "" and byte_size(prompt) <= 8_000,
      do: :ok,
      else: {:error, :invalid_delegation_request}
  end

  defp resolve_machine(user, machine_id) when is_binary(machine_id),
    do: Machines.get_machine(user.id, machine_id)

  defp resolve_machine(user, nil) do
    case Enum.filter(Machines.list_machines(user.id), &(&1.status == "active")) do
      [machine] -> {:ok, machine}
      [] -> {:error, :machine_not_found}
      _several -> {:error, :ambiguous_machine}
    end
  end

  defp resolve_machine(_user, _invalid), do: {:error, :machine_not_found}

  defp probed_agent_ids(%Machine{last_probe: %{"acp_agents" => agents}}) when is_list(agents) do
    ids =
      agents
      |> Enum.filter(&(is_map(&1) and is_binary(&1["id"]) and &1["id"] != ""))
      |> Enum.map(& &1["id"])

    if ids == [], do: :no_inventory, else: {:ok, ids}
  end

  defp probed_agent_ids(%Machine{}), do: :no_inventory

  defp put_optional(payload, _key, nil), do: payload

  defp put_optional(payload, key, value) when is_binary(value) and value != "",
    do: Map.put(payload, key, String.slice(value, 0, 500))

  defp put_optional(payload, _key, _value), do: payload

  defp unknown_agent_refusal(machine, agent_id, arguments, agent_ids) do
    listed = agent_ids |> Enum.take(@maximum_listed_agents) |> Enum.join(", ")

    base(machine, agent_id, arguments, "refused")
    |> put_in_result(
      "detail",
      String.slice(
        "agent_not_available: no probe evidence for \"#{agent_id}\" on this computer; " <>
          "probed agents: #{listed}",
        0,
        500
      )
    )
  end

  defp no_inventory_refusal(machine, agent_id, arguments) do
    base(machine, agent_id, arguments, "refused")
    |> put_in_result(
      "detail",
      "agent_not_available: no probed ACP agents are on record for this computer; " <>
        "run computer_probe first"
    )
  end

  defp cwd_required_refusal(machine, agent_id, arguments) do
    base(machine, agent_id, arguments, "refused")
    |> put_in_result(
      "detail",
      "cwd_required: name the project directory (for example /Users/…/work/sarah). " <>
        "Do not start in the pairing root when it contains multiple checkouts."
    )
  end

  @path_in_prompt ~r{(?<![A-Za-z0-9_])((?:~/|/)[^\s`'\"),]+)}

  defp resolve_cwd(arguments, prompt, context) do
    cond do
      usable_cwd?(arguments["cwd"]) ->
        {:ok, normalize_cwd(arguments["cwd"])}

      usable_cwd?(inferred = infer_cwd(prompt)) ->
        {:ok, normalize_cwd(inferred)}

      usable_cwd?(previous = last_cwd(context)) ->
        {:ok, normalize_cwd(previous)}

      true ->
        :error
    end
  end

  defp infer_cwd(prompt) when is_binary(prompt) do
    case Regex.run(@path_in_prompt, prompt, capture: :all_but_first) do
      [path] -> normalize_cwd(path)
      _none -> nil
    end
  end

  defp infer_cwd(_prompt), do: nil

  defp last_cwd(%{conversation_id: conversation_id}) when is_binary(conversation_id) do
    %Conversation{id: conversation_id}
    |> Work.recent_jobs(8)
    |> Enum.find_value(fn job ->
      cwd = job.delegation && job.delegation["cwd"]
      if usable_cwd?(cwd), do: cwd
    end)
  end

  defp last_cwd(_context), do: nil

  defp resolve_resume(arguments, context, cwd, agent_id) do
    cond do
      present_resume?(arguments["resume_session_id"]) ->
        String.slice(arguments["resume_session_id"], 0, 128)

      session = last_resumable_session(context, cwd, agent_id) ->
        session

      true ->
        nil
    end
  end

  defp last_resumable_session(%{conversation_id: conversation_id}, cwd, agent_id)
       when is_binary(conversation_id) do
    %Conversation{id: conversation_id}
    |> Work.recent_jobs(8)
    |> Enum.find_value(fn job ->
      params = job.delegation || %{}

      if job.status in ~w(failed interrupted cancelled) and
           params["cwd"] == cwd and params["agent_id"] == agent_id do
        session_from_report(job.report)
      end
    end)
  end

  defp last_resumable_session(_context, _cwd, _agent_id), do: nil

  defp session_from_report(report) when is_binary(report) do
    case Regex.run(~r/^Session: (\S+)/m, report) do
      [_, session_id] -> String.slice(session_id, 0, 128)
      _none -> nil
    end
  end

  defp session_from_report(_report), do: nil

  defp present_resume?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_resume?(_value), do: false

  defp usable_cwd?(cwd) when is_binary(cwd) do
    trimmed = normalize_cwd(cwd)
    trimmed != "" and not pairing_root?(trimmed) and not String.contains?(trimmed, "..")
  end

  defp usable_cwd?(_cwd), do: false

  defp pairing_root?(path) do
    path == "~/work" or String.ends_with?(path, "/work")
  end

  defp normalize_cwd(cwd) when is_binary(cwd) do
    cwd
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing(".")
    |> String.slice(0, 500)
  end

  defp normalize_cwd(_cwd), do: ""

  defp failure(machine, agent_id, arguments, reason),
    do: base(machine, agent_id, arguments, Atom.to_string(reason))

  # The delegation's mapped status is the STEP status too (ExecutionResult
  # status), so a timed-out or refused delegation never renders as a green
  # succeeded step while the honest outcome hides inside the result payload.
  # The rich result (partial output, session id) stays durable either way.
  defp base(machine, agent_id, arguments, status) do
    step_status =
      cond do
        status in OpenAgents.Tools.ExecutionResult.statuses() -> status
        # Starting the delegation succeeded — its own outcome arrives later as
        # the background job's report message.
        status == "started" -> "succeeded"
        status == "completed" -> "succeeded"
        true -> "failed"
      end

    %ExecutionResult{
      status: step_status,
      error:
        if(step_status == "succeeded",
          do: nil,
          else: %{"code" => text(status, 64), "message" => "The delegation ended #{status}."}
        ),
      result: %{
        "schema" => "sarah.computer_agent_result.v1",
        "status" => status,
        "machine_id" => machine.id,
        "machine_name" => machine.name,
        "agent_id" => text(agent_id, 64),
        "job_id" => "",
        "session_id" => "",
        "resume_session_id" => text(arguments["resume_session_id"], 128),
        "cwd" => text(arguments["cwd"], 500),
        "stop_reason" => "",
        "output" => "",
        "truncated" => false,
        "duration_ms" => 0,
        "detail" => ""
      },
      target_receipt_refs: ["machine:#{machine.id}"]
    }
  end

  defp put_in_result(%ExecutionResult{result: result} = execution, key, value),
    do: %ExecutionResult{execution | result: Map.put(result, key, value)}

  defp text(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp text(_value, _maximum), do: ""

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "machine_id" => %{"type" => "string", "maxLength" => 64},
        "agent_id" => %{"type" => "string", "maxLength" => 64},
        "prompt" => %{"type" => "string", "maxLength" => 8_000},
        "cwd" => %{"type" => "string", "maxLength" => 500},
        "resume_session_id" => %{"type" => "string", "maxLength" => 128}
      },
      "required" => ["agent_id", "prompt"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "schema" => %{"type" => "string", "maxLength" => 64},
        "status" => %{"type" => "string", "maxLength" => 32},
        "machine_id" => %{"type" => "string", "maxLength" => 64},
        "machine_name" => %{"type" => "string", "maxLength" => 80},
        "agent_id" => %{"type" => "string", "maxLength" => 64},
        "job_id" => %{"type" => "string", "maxLength" => 64},
        "session_id" => %{"type" => "string", "maxLength" => 128},
        "resume_session_id" => %{"type" => "string", "maxLength" => 128},
        "cwd" => %{"type" => "string", "maxLength" => 500},
        "stop_reason" => %{"type" => "string", "maxLength" => 32},
        "output" => %{"type" => "string", "maxLength" => 12_000},
        "truncated" => %{"type" => "boolean"},
        "duration_ms" => %{"type" => "integer"},
        "detail" => %{"type" => "string", "maxLength" => 500}
      },
      "required" => [
        "schema",
        "status",
        "machine_id",
        "machine_name",
        "agent_id",
        "job_id",
        "session_id",
        "resume_session_id",
        "cwd",
        "stop_reason",
        "output",
        "truncated",
        "duration_ms",
        "detail"
      ],
      "additionalProperties" => false
    }
  end
end
