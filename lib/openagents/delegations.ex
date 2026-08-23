defmodule OpenAgents.Delegations do
  @moduledoc """
  Unified, read-through delegation facade for Box and connected Computer work.

  The Box run and Work delegation ledgers remain authoritative. This module
  stores no delegation state and derives every identifier and projection from
  those substrate records.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Agents
  alias OpenAgents.Box.{ConversationBox, Fleet, Run}
  alias OpenAgents.BoxRuns
  alias OpenAgents.ComputerAgentJobs
  alias OpenAgents.ComputerProjection
  alias OpenAgents.Conversations.{Conversation, Visitor}
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Machine
  alias OpenAgents.Repo
  alias OpenAgents.Tools.BoxOutput
  alias OpenAgents.Work
  alias OpenAgents.Work.Job

  @maximum_targets 32
  @maximum_delegations 32

  @type caller :: %{user: User.t() | nil, agent: struct() | nil, scopes: [String.t()]}

  @spec inventory(caller(), String.t()) :: {:ok, map()} | {:error, atom()}
  def inventory(caller, conversation_id) when is_map(caller) and is_binary(conversation_id) do
    with {:ok, owners} <- inventory_owners(caller, conversation_id) do
      boxes = Enum.flat_map(owners.boxes, &box_targets(&1, conversation_id))
      computers = Enum.flat_map(owners.computers, &computer_targets/1)

      {:ok,
       %{
         "schema" => "openagents.delegation_targets.v1",
         "conversation_id" => conversation_id,
         "targets" => Enum.take(boxes ++ computers, @maximum_targets)
       }}
    end
  end

  defp inventory_owners(%{user: %User{} = user, scopes: scopes}, conversation_id) do
    if conversation_owned?(user, conversation_id) do
      {:ok,
       %{
         boxes: if("box:control" in scopes, do: [user], else: []),
         computers: if("computer:control" in scopes, do: [user], else: [])
       }}
    else
      {:error, :target_not_found}
    end
  end

  defp inventory_owners(%{agent: agent}, conversation_id) when not is_nil(agent) do
    boxes =
      agent
      |> Agents.control_owner("box")
      |> owner_list()
      |> Enum.filter(&conversation_owned?(&1, conversation_id))

    computers =
      agent
      |> Agents.control_owner("computer")
      |> owner_list()
      |> Enum.filter(&conversation_owned?(&1, conversation_id))

    if Enum.any?(boxes ++ computers, &conversation_owned?(&1, conversation_id)),
      do: {:ok, %{boxes: boxes, computers: computers}},
      else: {:error, :target_not_found}
  end

  defp inventory_owners(_caller, _conversation_id), do: {:error, :target_not_found}
  defp owner_list(%User{} = owner), do: [owner]
  defp owner_list(nil), do: []

  @spec start(caller(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def start(caller, conversation_id, params)
      when is_map(caller) and is_binary(conversation_id) and is_map(params) do
    with {:ok, kind, target_id} <- parse_target_id(params["target_id"]),
         {:ok, owner} <- conversation_owner(caller, conversation_id),
         {:ok, target} <- resolve_target(caller, owner, conversation_id, kind, target_id),
         {:ok, result} <- dispatch_start(caller, owner, conversation_id, kind, target, params) do
      {:ok, delegation_projection(kind, result)}
    end
  end

  @spec get(caller(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def get(caller, conversation_id, delegation_id)
      when is_map(caller) and is_binary(conversation_id) and is_binary(delegation_id) do
    with {:ok, kind, id} <- parse_delegation_id(delegation_id),
         {:ok, owner} <- conversation_owner(caller, conversation_id),
         {:ok, record} <- resolve_delegation(caller, owner, conversation_id, kind, id) do
      {:ok, delegation_projection(kind, record)}
    end
  end

  @spec cancel(caller(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def cancel(caller, conversation_id, delegation_id)
      when is_map(caller) and is_binary(conversation_id) and is_binary(delegation_id) do
    with {:ok, kind, id} <- parse_delegation_id(delegation_id),
         {:ok, owner} <- conversation_owner(caller, conversation_id),
         {:ok, record} <- resolve_delegation(caller, owner, conversation_id, kind, id),
         {:ok, cancelled} <- dispatch_cancel(kind, record) do
      {:ok, delegation_projection(kind, cancelled)}
    end
  end

  @doc "Durable projection used by the `/chat` fleet panel."
  @spec projection(User.t(), String.t()) :: map()
  def projection(%User{} = user, conversation_id) when is_binary(conversation_id) do
    base = Fleet.projection(conversation_id)
    computers = computer_targets(user)
    jobs = latest_jobs(user.id, conversation_id)

    Map.merge(base, %{
      computers: Enum.map(computers, &computer_fleet_view(&1, Map.get(jobs, &1["computer_id"]))),
      maximum_computers: @maximum_targets
    })
  end

  defp conversation_owner(%{user: %User{} = user}, conversation_id) do
    case OpenAgents.Conversations.get_conversation_for_user(user, conversation_id) do
      %Conversation{} -> {:ok, user}
      nil -> {:error, :target_not_found}
    end
  end

  defp conversation_owner(%{agent: agent}, conversation_id) when not is_nil(agent) do
    case Agents.linked_owner(agent) do
      %User{} = owner ->
        if conversation_owned?(owner, conversation_id),
          do: {:ok, owner},
          else: {:error, :target_not_found}

      nil ->
        {:error, :target_not_found}
    end
  end

  defp conversation_owner(_caller, _conversation_id), do: {:error, :target_not_found}

  defp conversation_owned?(%User{} = user, conversation_id),
    do: not is_nil(OpenAgents.Conversations.get_conversation_for_user(user, conversation_id))

  defp box_targets(%User{id: user_id}, conversation_id) do
    Repo.all(
      from box in ConversationBox,
        join: conversation in Conversation,
        on: conversation.id == box.conversation_id,
        join: visitor in Visitor,
        on: visitor.id == conversation.visitor_id,
        where: box.conversation_id == ^conversation_id and visitor.user_id == ^user_id,
        order_by: [asc: box.inserted_at],
        limit: ^@maximum_targets
    )
    |> Enum.map(fn box ->
      %{
        "id" => "box:" <> box.id,
        "kind" => "box",
        "label" => box.label,
        "state" => box.state,
        "box_id" => box.box_id,
        "stopped_at" => iso8601(box.stopped_at)
      }
    end)
  end

  defp computer_targets(%User{id: user_id}) do
    Machines.list_machines(user_id)
    |> Enum.take(@maximum_targets)
    |> Enum.map(fn machine ->
      machine
      |> ComputerProjection.project()
      |> Map.merge(%{
        "id" => "computer:" <> machine.id,
        "kind" => "computer",
        "computer_id" => machine.id
      })
    end)
  end

  defp resolve_target(caller, owner, conversation_id, "box", target_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(target_id),
         %ConversationBox{} = box <-
           Repo.one(
             from b in ConversationBox,
               where: b.id == ^uuid and b.conversation_id == ^conversation_id
           ),
         true <- conversation_owned?(owner, conversation_id) do
      if authorized?(caller, "box", owner),
        do: {:ok, box},
        else: {:error, target_error(caller, "box")}
    else
      _ -> {:error, :target_not_found}
    end
  end

  defp resolve_target(caller, owner, conversation_id, "computer", target_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(target_id),
         %Machine{} = machine <- Repo.get_by(Machine, id: uuid, user_id: owner.id),
         true <- conversation_owned?(owner, conversation_id) do
      if authorized?(caller, "computer", owner),
        do: {:ok, machine},
        else: {:error, target_error(caller, "computer")}
    else
      _ -> {:error, :target_not_found}
    end
  end

  defp dispatch_start(caller, _owner, conversation_id, "box", %ConversationBox{} = box, params) do
    command = params["command"]
    principal = principal(caller)

    if valid_command?(command) do
      BoxRuns.start_run(
        conversation_id,
        box.box_id,
        principal,
        command,
        params["idempotency_key"] || Ecto.UUID.generate()
      )
    else
      {:error, :invalid_command}
    end
  end

  defp dispatch_start(_caller, owner, conversation_id, "computer", %Machine{} = machine, params) do
    case OpenAgents.Conversations.get_conversation_for_user(owner, conversation_id) do
      %Conversation{} = conversation ->
        ComputerAgentJobs.start(owner, machine, conversation, params)

      nil ->
        {:error, :target_not_found}
    end
  end

  defp resolve_delegation(caller, owner, conversation_id, "box", id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Run{} = run <-
           Repo.one(
             from r in Run,
               join: box in ConversationBox,
               on: box.id == r.conversation_box_id,
               where: r.id == ^uuid and r.conversation_id == ^conversation_id,
               preload: [conversation_box: box]
           ),
         true <- conversation_owned?(owner, conversation_id) do
      if authorized?(caller, "box", owner),
        do: {:ok, run},
        else: {:error, target_error(caller, "box")}
    else
      _ -> {:error, :target_not_found}
    end
  end

  defp resolve_delegation(caller, owner, conversation_id, "computer", id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Job{kind: "delegation"} = job <-
           Repo.one(from j in Job, where: j.id == ^uuid and j.conversation_id == ^conversation_id),
         %Visitor{user_id: user_id} <- Repo.get(Visitor, job.owner_visitor_id),
         true <- user_id == owner.id do
      if authorized?(caller, "computer", owner),
        do: {:ok, job},
        else: {:error, target_error(caller, "computer")}
    else
      _ -> {:error, :target_not_found}
    end
  end

  defp dispatch_cancel("box", %Run{} = run), do: BoxRuns.cancel(run)

  defp dispatch_cancel("computer", %Job{} = job),
    do: Work.cancel_job(job.id) |> cancelled_job(job)

  defp cancelled_job({:ok, :stopping}, job), do: {:ok, %{job | status: "stopping"}}
  defp cancelled_job({:ok, _result}, job), do: {:ok, Repo.get!(Job, job.id)}
  defp cancelled_job(error, _job), do: error

  defp delegation_projection("box", %Run{} = run) do
    {output, truncated?} = BoxOutput.bounded(run.output)

    %{
      "id" => "box-run:" <> run.id,
      "kind" => "box",
      "target_id" => "box:" <> run.conversation_box.id,
      "state" => run.state,
      "output" => output,
      "output_truncated" => truncated?,
      "exit_status" => run.exit_status,
      "failure_reason" => bounded(run.failure_reason, 500),
      "finished_at" => iso8601(run.finished_at)
    }
  end

  defp delegation_projection("computer", %Job{} = job) do
    delegation = job.delegation || %{}
    prompt = delegation["prompt"]
    {report, truncated?} = bounded_output(job.report, prompt)

    %{
      "id" => "computer-job:" <> job.id,
      "kind" => "computer",
      "target_id" => "computer:" <> job.machine_id,
      "state" => job.status,
      "agent_id" => delegation["agent_id"],
      "output" => report,
      "output_truncated" => truncated?,
      "failure_reason" => bounded(job.error_code, 500),
      "finished_at" => iso8601(job.completed_at)
    }
  end

  defp computer_fleet_view(target, nil), do: Map.put(target, "delegation", nil)

  defp computer_fleet_view(target, %Job{} = job) do
    projection = delegation_projection("computer", job)
    Map.put(target, "delegation", projection)
  end

  defp latest_jobs(user_id, conversation_id) do
    Repo.all(
      from job in Job,
        join: visitor in Visitor,
        on: visitor.id == job.owner_visitor_id,
        where:
          job.kind == "delegation" and job.conversation_id == ^conversation_id and
            visitor.user_id == ^user_id,
        order_by: [asc: job.machine_id, desc: job.inserted_at, desc: job.id],
        limit: ^(@maximum_delegations * 4)
    )
    |> Enum.reduce(%{}, fn job, acc -> Map.put_new(acc, job.machine_id, job) end)
  end

  defp authorized?(%{user: %User{}, scopes: scopes}, kind, _owner),
    do: required_scope(kind) in scopes

  defp authorized?(%{agent: agent}, kind, %User{} = owner) when not is_nil(agent),
    do: Agents.control_granted_by?(agent, owner, kind)

  defp authorized?(_caller, _kind, _owner), do: false

  defp target_error(%{agent: agent}, "box") when not is_nil(agent),
    do: :agent_box_control_forbidden

  defp target_error(%{agent: agent}, "computer") when not is_nil(agent),
    do: :agent_computer_control_forbidden

  defp target_error(_caller, _kind), do: :scope_forbidden

  defp required_scope("box"), do: "box:control"
  defp required_scope("computer"), do: "computer:control"

  defp principal(%{agent: %{id: id}}), do: %{"type" => "agent", "id" => id}
  defp principal(%{user: %{id: id}}), do: %{"type" => "user", "id" => id}

  defp parse_target_id("box:" <> id) when id != "", do: cast_prefixed_id("box", id)
  defp parse_target_id("computer:" <> id) when id != "", do: cast_prefixed_id("computer", id)
  defp parse_target_id(_id), do: {:error, :target_not_found}

  defp parse_delegation_id("box-run:" <> id) when id != "", do: cast_prefixed_id("box", id)

  defp parse_delegation_id("computer-job:" <> id) when id != "",
    do: cast_prefixed_id("computer", id)

  defp parse_delegation_id(_id), do: {:error, :target_not_found}

  defp cast_prefixed_id(kind, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, kind, uuid}
      :error -> {:error, :target_not_found}
    end
  end

  defp valid_command?(command) when is_binary(command),
    do:
      String.trim(command) != "" and String.valid?(command) and
        not String.contains?(command, "\0") and byte_size(command) <= 8_000

  defp valid_command?(_command), do: false

  defp bounded(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded(_value, _maximum), do: nil

  defp bounded_output(nil, _prompt), do: {nil, false}

  defp bounded_output(value, prompt) when is_binary(value) do
    redacted =
      if is_binary(prompt) and prompt != "",
        do: String.replace(value, prompt, "[redacted]"),
        else: value

    BoxOutput.bounded(redacted)
  end

  defp bounded_output(_value, _prompt), do: {nil, false}

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
