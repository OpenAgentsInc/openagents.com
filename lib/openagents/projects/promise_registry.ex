defmodule OpenAgents.Projects.PromiseRegistry do
  @moduledoc "Validation and privacy projections for promise registry items."

  import Ecto.Query

  alias OpenAgents.Changelog.Entry
  alias OpenAgents.Compensation.OutcomeDecision
  alias OpenAgents.Forge.{BuildReceipt, DeployReceipt}
  alias OpenAgents.ProjectFields.ProjectField
  alias OpenAgents.Projects.Project
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @states ~w(LIVE GATED WITHDRAWN)
  @promise_id ~r/^[a-z0-9][a-z0-9_]{2,63}$/
  @required_fields ~w(id problem claim scope acceptance_criteria success_metrics owner target evidence)
  @required_text_fields ~w(problem claim scope owner target)

  def states, do: @states

  def context(%Project{id: project_id}) do
    fields =
      Repo.all(
        from field in ProjectField,
          where: field.project_id == ^project_id and field.data_type == "promise_state"
      )

    case fields do
      [field] -> %{field: field, registry?: valid_registry_field?(field)}
      _other -> %{field: nil, registry?: false}
    end
  end

  def registry?(%Project{} = project), do: context(project).registry?

  def registry?(%{registry?: registry?}), do: registry?

  def registry?(_project), do: false

  def field(%Project{id: project_id}) do
    Repo.one(
      from field in ProjectField,
        where: field.project_id == ^project_id and field.data_type == "promise_state"
    )
  end

  def field(%{field: field}), do: field

  def state(%Project{} = project, values) when is_map(values) do
    state(context(project), values)
  end

  def state(%{field: %ProjectField{name: name}}, values) when is_map(values) do
    Map.get(values, name)
  end

  def state(_context, _values), do: nil

  def projection(context, values, reader) when is_map(values) do
    values
    |> redact_values(reader)
    |> projection_from_redacted(context)
  end

  def projection_from_redacted(context, values) when is_map(values) do
    if context.registry? do
      %{
        record: Map.get(values, "promise"),
        state: state(context, values),
        verified_at: get_in(values, ["promise", "verified_at"]),
        bounty_candidate: bounty_candidate?(context, values)
      }
    end
  end

  def projection_from_redacted(_context, _values), do: nil

  def bounty_candidate?(%{registry?: true} = context, values) do
    state(context, values) == "GATED" and
      values
      |> get_in(["promise", "gate", "missing"])
      |> present?()
  end

  def bounty_candidate?(_context, _values), do: false

  def validate_field(changeset) do
    data_type = Ecto.Changeset.get_field(changeset, :data_type)
    options = Ecto.Changeset.get_field(changeset, :options)

    cond do
      data_type != "promise_state" ->
        changeset

      options != %{"values" => @states} ->
        Ecto.Changeset.add_error(
          changeset,
          :options,
          "must contain exactly LIVE, GATED, and WITHDRAWN"
        )

      true ->
        changeset
    end
  end

  def validate_values(project, values, actor \\ nil)

  def validate_values(%Project{} = project, values, actor) when is_map(values) do
    promise_context = context(project)

    if promise_context.registry? do
      with {:ok, state} <- fetch_state(promise_context, values),
           {:ok, promise} <- validate_promise(Map.get(values, "promise")) do
        values = Map.put(values, "promise", promise)

        with :ok <- validate_state(state, promise, project, actor) do
          {:ok, put_verified_at(values, project, state, promise)}
        else
          {:error, field, message} -> {:error, %{field => [message]}}
        end
      else
        {:error, field, message} -> {:error, %{field => [message]}}
      end
    else
      {:ok, values}
    end
  end

  def validate_values(_project, values, _actor), do: {:ok, values}

  def redact_values(values, reader) when is_map(values) do
    case Map.get(values, "promise") do
      promise when is_map(promise) ->
        evidence =
          case Map.get(promise, "evidence") do
            evidence when is_list(evidence) ->
              Enum.filter(evidence, &readable_evidence?(&1, reader))

            _other ->
              []
          end

        put_in(values, ["promise", "evidence"], evidence)

      _other ->
        values
    end
  end

  def redact_values(values, _reader), do: values

  def resolvable_evidence?(
        %{"kind" => "accepted_outcome", "decision_receipt_ref" => ref} = evidence,
        reader
      ) do
    readable_evidence?(evidence, reader) and accepted_outcome?(ref)
  end

  def resolvable_evidence?(_evidence, _reader), do: false

  def readable_evidence?(%{"kind" => "issue"} = evidence, reader) do
    with owner when is_binary(owner) <- evidence["owner"],
         repo when is_binary(repo) <- evidence["repo"],
         {:ok, number} <- to_number(evidence["number"]),
         %Repository{} = repository <- visible_repository(owner, repo, reader) do
      issue_exists?(repository.id, number)
    else
      _ -> false
    end
  end

  def readable_evidence?(%{"kind" => "changelog", "slug" => slug}, _reader) do
    Repo.exists?(
      from entry in Entry,
        where:
          fragment("?->>'slug' = ?", entry.detail, ^slug) and entry.visibility in ["l2", "l3"]
    )
  end

  def readable_evidence?(%{"kind" => "receipt", "id" => id}, _reader) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.exists?(from receipt in BuildReceipt, where: receipt.id == ^uuid) or
          Repo.exists?(from receipt in DeployReceipt, where: receipt.id == ^uuid)

      :error ->
        false
    end
  end

  def readable_evidence?(
        %{"kind" => "accepted_outcome", "decision_receipt_ref" => ref},
        _reader
      )
      when is_binary(ref),
      do:
        Repo.exists?(
          from decision in OutcomeDecision, where: decision.decision_receipt_ref == ^ref
        )

  def readable_evidence?(%{"kind" => "link", "url" => url}, _reader), do: valid_link?(url)
  def readable_evidence?(_evidence, _reader), do: false

  defp fetch_state(promise_context, values) do
    case state(promise_context, values) do
      state when state in @states -> {:ok, state}
      _ -> {:error, :values, "must include a valid promise state"}
    end
  end

  defp validate_promise(promise) when is_map(promise) do
    cond do
      Enum.any?(@required_fields, &(not Map.has_key?(promise, &1))) ->
        {:error, :values,
         "promise must include id, problem, claim, scope, acceptance_criteria, success_metrics, owner, target, and evidence"}

      not is_binary(promise["id"]) or not Regex.match?(@promise_id, promise["id"]) ->
        {:error, :values, "promise.id must match ^[a-z0-9][a-z0-9_]{2,63}$"}

      not Enum.all?(@required_text_fields, &present?(Map.get(promise, &1))) ->
        {:error, :values, "promise text fields must be nonempty strings"}

      not nonempty_list?(promise["acceptance_criteria"]) ->
        {:error, :values, "promise.acceptance_criteria must be a nonempty list"}

      not nonempty_list?(promise["success_metrics"]) ->
        {:error, :values, "promise.success_metrics must be a nonempty list"}

      not nonempty_text_list?(promise["acceptance_criteria"]) ->
        {:error, :values, "promise.acceptance_criteria must contain nonempty strings"}

      not nonempty_text_list?(promise["success_metrics"]) ->
        {:error, :values, "promise.success_metrics must contain nonempty strings"}

      not is_list(promise["evidence"]) ->
        {:error, :values, "promise.evidence must be a list"}

      not Enum.all?(promise["evidence"], &valid_evidence_shape?/1) ->
        {:error, :values, "promise.evidence contains an invalid entry"}

      true ->
        {:ok, Map.delete(promise, "verified_at")}
    end
  end

  defp validate_promise(_promise), do: {:error, :values, "values.promise is required"}

  defp validate_state("LIVE", promise, _project, actor) do
    if Enum.any?(promise["evidence"], &resolvable_evidence?(&1, actor)) do
      :ok
    else
      {:error, :values, "LIVE requires at least one accepted-outcome evidence entry"}
    end
  end

  defp validate_state("GATED", promise, _project, _actor) do
    if complete_map?(promise["gate"], ~w(missing owner next_review)) do
      :ok
    else
      {:error, :values, "GATED requires gate.missing, gate.owner, and gate.next_review"}
    end
  end

  defp validate_state("WITHDRAWN", promise, _project, _actor) do
    if complete_map?(promise["withdrawal"], ~w(reason replacement date)) do
      :ok
    else
      {:error, :values,
       "WITHDRAWN requires withdrawal.reason, withdrawal.replacement, and withdrawal.date"}
    end
  end

  defp put_verified_at(values, _project, "LIVE", promise) do
    Map.put(values, "promise", Map.put(promise, "verified_at", DateTime.utc_now()))
  end

  defp put_verified_at(values, _project, _state, _promise), do: values

  defp valid_evidence_shape?(%{
         "kind" => "issue",
         "owner" => owner,
         "repo" => repo,
         "number" => number
       }),
       do: present?(owner) and present?(repo) and valid_number?(number)

  defp valid_evidence_shape?(%{"kind" => "changelog", "slug" => slug}), do: present?(slug)
  defp valid_evidence_shape?(%{"kind" => "receipt", "id" => id}), do: present?(id)

  defp valid_evidence_shape?(%{"kind" => "accepted_outcome", "decision_receipt_ref" => ref}),
    do: present?(ref)

  defp valid_evidence_shape?(%{"kind" => "link", "url" => url}), do: valid_link?(url)
  defp valid_evidence_shape?(_evidence), do: false

  defp visible_repository(owner, repo, reader) do
    Repositories.get_visible_by_path!(owner, repo, reader)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp issue_exists?(repository_id, number) do
    Repo.exists?(
      from issue in OpenAgents.Issues.Issue,
        where: issue.repository_id == ^repository_id and issue.number == ^number
    )
  end

  defp accepted_outcome?(ref) when is_binary(ref) do
    Repo.exists?(
      from decision in OutcomeDecision,
        where: decision.decision_receipt_ref == ^ref and decision.decision == "accepted"
    )
  end

  defp accepted_outcome?(_ref), do: false

  defp valid_registry_field?(%ProjectField{options: %{"values" => values}})
       when values == @states,
       do: true

  defp valid_registry_field?(_field), do: false

  defp complete_map?(map, keys) when is_map(map), do: Enum.all?(keys, &present?(map[&1]))
  defp complete_map?(_map, _keys), do: false
  defp nonempty_list?(value), do: is_list(value) and value != []
  defp nonempty_text_list?(value), do: Enum.all?(value, &present?/1)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_link?(url), do: present?(url) and valid_url?(url)
  defp valid_number?(value), do: match?({:ok, _}, to_number(value))

  defp valid_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp to_number(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp to_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp to_number(_value), do: :error
end
