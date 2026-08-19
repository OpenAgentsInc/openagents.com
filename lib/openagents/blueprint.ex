defmodule OpenAgents.Blueprint do
  @moduledoc """
  Source-linked, immutable revisions of platform-owned Sarah facts.

  Blueprint facts can shape persona, role, and evaluation projections. They
  cannot grant runtime authority, advertise pricing, or ingest private user
  memory. Every change creates a complete new revision; admitted rows are
  protected from update and deletion by PostgreSQL triggers.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.Blueprint.{Fact, Revision}
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @runtime_compatibility 1
  @private_source_prefixes ["conversation:", "message:", "profile-memory:", "visitor:"]
  @authority_claim ~r/\b(can|may|has authority to|is authorized to)\s+(access|execute|charge|set prices?|use tools?|call tools?)\b/i
  @pricing_claim ~r/\b(pricing is|price is|costs? \$|subscription is)\b/i

  @type projection :: %{
          revision: String.t(),
          digest: String.t(),
          instruction_fragment: String.t(),
          persona_fragment: String.t(),
          role_fragments: [map()],
          eval_examples: [map()]
        }

  @doc "Appends a revision, carrying forward all current facts and adding new facts."
  @spec append_revision(map(), [map()]) :: {:ok, projection()} | {:error, term()}
  def append_revision(revision_attributes, new_facts)
      when is_map(revision_attributes) and is_list(new_facts) do
    Repo.transaction(fn ->
      parent = latest_revision(lock: true)
      revision = fetch!(revision_attributes, :revision)
      carried_facts = if parent, do: facts_for(parent), else: []

      candidate_facts =
        Enum.map(carried_facts, &fact_attributes/1) ++
          Enum.map(new_facts, &normalize_new_fact(&1, revision))

      admit_revision!(parent, revision_attributes, candidate_facts)
    end)
    |> unwrap_transaction()
  rescue
    error in ArgumentError -> {:error, error.message}
  end

  @doc "Creates a revision that retires the named active facts."
  @spec retire_facts(map(), [String.t()]) :: {:ok, projection()} | {:error, term()}
  def retire_facts(revision_attributes, fact_ids)
      when is_map(revision_attributes) and is_list(fact_ids) and fact_ids != [] do
    Repo.transaction(fn ->
      parent = latest_revision(lock: true) || Repo.rollback(:no_admitted_blueprint)
      revision = fetch!(revision_attributes, :revision)
      active_facts = facts_for(parent)
      active_ids = active_facts |> Enum.reject(& &1.retired_revision) |> MapSet.new(& &1.fact_id)
      requested_ids = MapSet.new(fact_ids)

      unless MapSet.subset?(requested_ids, active_ids) do
        Repo.rollback({:unknown_or_retired_facts, MapSet.difference(requested_ids, active_ids)})
      end

      candidate_facts =
        Enum.map(active_facts, fn fact ->
          attributes = fact_attributes(fact)

          if MapSet.member?(requested_ids, fact.fact_id),
            do: Map.put(attributes, :retired_revision, revision),
            else: attributes
        end)

      admit_revision!(parent, revision_attributes, candidate_facts)
    end)
    |> unwrap_transaction()
  rescue
    error in ArgumentError -> {:error, error.message}
  end

  def retire_facts(_revision_attributes, _fact_ids), do: {:error, :invalid_retirement}

  @doc "Returns the latest admitted compatible projection, or explicitly none."
  @spec current_projection() :: {:ok, projection() | nil} | {:error, term()}
  def current_projection do
    case latest_revision() do
      nil -> {:ok, nil}
      revision -> projection(revision)
    end
  end

  @doc "Compiles and verifies one admitted revision deterministically."
  @spec projection(Revision.t() | String.t()) :: {:ok, projection()} | {:error, term()}
  def projection(revision_name) when is_binary(revision_name) do
    case Repo.get_by(Revision, revision: revision_name) do
      nil -> {:error, :blueprint_revision_not_found}
      revision -> projection(revision)
    end
  end

  def projection(%Revision{} = revision) do
    facts = facts_for(revision)

    with :ok <- validate_revision(revision),
         :ok <- validate_facts(facts),
         expected_digest <- revision_digest(revision, facts),
         :ok <- compare_digest(revision.digest, expected_digest) do
      {:ok, compile_projection(revision, facts)}
    end
  end

  @doc "Returns each immutable appearance of a stable fact ID for provenance inspection."
  def explain(fact_id) when is_binary(fact_id) do
    from(f in Fact,
      join: r in assoc(f, :revision),
      where: f.fact_id == ^fact_id,
      order_by: [asc: r.sequence],
      select: %{
        revision: r.revision,
        revision_digest: r.digest,
        introduced_revision: f.introduced_revision,
        retired_revision: f.retired_revision,
        source_type: f.source_type,
        source_ref: f.source_ref,
        source_status: f.source_status,
        source_digest: f.source_digest,
        author: f.author,
        reason: f.reason,
        receipt: f.receipt
      }
    )
    |> Repo.all()
  end

  defp admit_revision!(parent, revision_attributes, candidate_facts) do
    revision = fetch!(revision_attributes, :revision)
    sequence = if parent, do: parent.sequence + 1, else: 1
    compatibility_min = fetch!(revision_attributes, :compatibility_min)
    compatibility_max = fetch!(revision_attributes, :compatibility_max)

    normalized_revision = %{
      revision: revision,
      sequence: sequence,
      parent_revision: if(parent, do: parent.revision),
      status: "admitted",
      compatibility_min: compatibility_min,
      compatibility_max: compatibility_max,
      author: fetch!(revision_attributes, :author),
      reason: fetch!(revision_attributes, :reason),
      receipt: get(revision_attributes, :receipt, %{})
    }

    candidate_facts = Enum.map(candidate_facts, &normalize_fact/1)

    with :ok <- validate_candidate_revision(normalized_revision),
         :ok <- validate_facts(candidate_facts),
         :ok <- validate_unique_fact_ids(candidate_facts) do
      digest = revision_digest(normalized_revision, candidate_facts)

      Multi.new()
      |> Multi.insert(
        :revision,
        Revision.changeset(%Revision{}, Map.put(normalized_revision, :digest, digest))
      )
      |> Multi.run(:facts, fn repo, %{revision: stored_revision} ->
        insert_facts(repo, stored_revision, candidate_facts)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{revision: stored_revision}} ->
          case projection(stored_revision) do
            {:ok, compiled} -> compiled
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, operation, changeset, _changes} ->
          Repo.rollback({operation, changeset})
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_facts(repo, revision, facts) do
    Enum.reduce_while(facts, {:ok, []}, fn attributes, {:ok, inserted} ->
      changeset = Fact.changeset(%Fact{revision_id: revision.id}, attributes)

      case repo.insert(changeset) do
        {:ok, fact} -> {:cont, {:ok, [fact | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp latest_revision(options \\ []) do
    query =
      from(r in Revision, where: r.status == "admitted", order_by: [desc: r.sequence], limit: 1)

    query = if Keyword.get(options, :lock), do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp facts_for(%Revision{id: revision_id}) do
    from(f in Fact, where: f.revision_id == ^revision_id, order_by: [asc: f.fact_id])
    |> Repo.all()
  end

  defp normalize_new_fact(attributes, revision) do
    attributes
    |> atomize_keys()
    |> Map.put(:introduced_revision, revision)
    |> Map.put(:retired_revision, nil)
  end

  defp normalize_fact(%Fact{} = fact), do: fact

  defp normalize_fact(attributes) when is_map(attributes) do
    attributes
    |> atomize_keys()
    |> Map.put_new(:receipt, %{})
  end

  defp validate_candidate_revision(revision) do
    cond do
      not positive_integer?(revision.compatibility_min) ->
        {:error, :invalid_compatibility_range}

      not positive_integer?(revision.compatibility_max) ->
        {:error, :invalid_compatibility_range}

      revision.compatibility_max < revision.compatibility_min ->
        {:error, :invalid_compatibility_range}

      not compatible?(revision) ->
        {:error, :stale_or_incompatible_revision}

      true ->
        :ok
    end
  end

  defp validate_revision(%Revision{status: "admitted"} = revision) do
    if compatible?(revision), do: :ok, else: {:error, :stale_or_incompatible_revision}
  end

  defp validate_revision(_revision), do: {:error, :unadmitted_revision}

  defp validate_facts(facts) when is_list(facts) do
    Enum.reduce_while(facts, :ok, fn fact, :ok ->
      case validate_fact(fact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_fact(fact) do
    value_type = value(fact, :value_type)
    typed_value = value(fact, :typed_value)
    source_ref = value(fact, :source_ref)

    cond do
      not non_empty_string?(value(fact, :fact_id)) ->
        {:error, :missing_fact_id}

      value(fact, :section) not in ~w(identity voice vocabulary roles product_truths rules examples) ->
        {:error, {:invalid_fact_section, value(fact, :fact_id)}}

      value_type not in ~w(text terms role example) ->
        {:error, {:invalid_fact_value_type, value(fact, :fact_id)}}

      value(fact, :source_type) not in ~w(repository_document release_artifact persona_source founder_direction) ->
        {:error, {:private_or_unadmitted_source_type, value(fact, :fact_id)}}

      value(fact, :source_status) not in ~w(admitted binding historical_evidence) ->
        {:error, {:unadmitted_source_status, value(fact, :fact_id)}}

      not match?(%DateTime{}, value(fact, :source_observed_at)) ->
        {:error, {:missing_source_observation_time, value(fact, :fact_id)}}

      private_source_ref?(source_ref) ->
        {:error, {:private_memory_source_forbidden, value(fact, :fact_id)}}

      not valid_digest?(value(fact, :source_digest)) ->
        {:error, {:invalid_source_digest, value(fact, :fact_id)}}

      not non_empty_string?(value(fact, :introduced_revision)) ->
        {:error, {:missing_introduced_revision, value(fact, :fact_id)}}

      not non_empty_string?(value(fact, :author)) or
          not non_empty_string?(value(fact, :reason)) ->
        {:error, {:missing_admission_provenance, value(fact, :fact_id)}}

      not compatible?(fact) ->
        {:error, {:stale_or_incompatible_fact, value(fact, :fact_id)}}

      not valid_typed_value?(value_type, typed_value) ->
        {:error, {:invalid_typed_value, value(fact, :fact_id)}}

      authority_claim?(typed_value) ->
        {:error, {:runtime_authority_claim_forbidden, value(fact, :fact_id)}}

      true ->
        :ok
    end
  end

  defp validate_unique_fact_ids(facts) do
    ids = Enum.map(facts, &value(&1, :fact_id))
    if length(ids) == MapSet.size(MapSet.new(ids)), do: :ok, else: {:error, :conflicting_fact_ids}
  end

  defp valid_typed_value?("text", %{"text" => text}), do: non_empty_string?(text)

  defp valid_typed_value?("terms", %{"terms" => terms}) when is_list(terms),
    do: terms != [] and Enum.all?(terms, &non_empty_string?/1)

  defp valid_typed_value?("role", %{"role_id" => role_id, "instruction" => instruction}),
    do: non_empty_string?(role_id) and non_empty_string?(instruction)

  defp valid_typed_value?("example", %{"input" => input, "properties" => properties})
       when is_list(properties),
       do:
         non_empty_string?(input) and properties != [] and
           Enum.all?(properties, &non_empty_string?/1)

  defp valid_typed_value?(_value_type, _typed_value), do: false

  defp authority_claim?(typed_value) do
    typed_value
    |> strings()
    |> Enum.any?(&(Regex.match?(@authority_claim, &1) or Regex.match?(@pricing_claim, &1)))
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(_value), do: []

  defp private_source_ref?(source_ref) when is_binary(source_ref) do
    Enum.any?(@private_source_prefixes, &String.starts_with?(source_ref, &1))
  end

  defp private_source_ref?(_source_ref), do: true

  defp compile_projection(revision, facts) do
    active_facts = Enum.reject(facts, &value(&1, :retired_revision))

    persona_facts =
      Enum.filter(
        active_facts,
        &(value(&1, :section) != "roles" and value(&1, :section) != "examples")
      )

    role_facts = Enum.filter(active_facts, &(value(&1, :section) == "roles"))
    example_facts = Enum.filter(active_facts, &(value(&1, :section) == "examples"))

    persona_fragment = render_facts(persona_facts)

    %{
      revision: revision.revision,
      digest: revision.digest,
      instruction_fragment: persona_fragment,
      persona_fragment: persona_fragment,
      role_fragments:
        Enum.map(role_facts, fn fact ->
          %{
            fact_id: value(fact, :fact_id),
            role_id: value(fact, :typed_value)["role_id"],
            instruction: value(fact, :typed_value)["instruction"]
          }
        end),
      eval_examples:
        Enum.map(example_facts, fn fact ->
          value(fact, :typed_value) |> Map.put("fact_id", value(fact, :fact_id))
        end)
    }
  end

  defp render_facts([]), do: "No Sarah Blueprint facts are active for this revision."

  defp render_facts(facts) do
    facts
    |> Enum.map(fn fact ->
      Jason.encode!(%{
        "fact_id" => value(fact, :fact_id),
        "section" => value(fact, :section),
        "type" => value(fact, :value_type),
        "value" => value(fact, :typed_value)
      })
    end)
    |> Enum.join("\n")
  end

  defp revision_digest(revision, facts) do
    Canonical.digest!(%{
      "schema" => "sarah.blueprint.revision.v1",
      "revision" => value(revision, :revision),
      "sequence" => value(revision, :sequence),
      "parent_revision" => value(revision, :parent_revision),
      "compatibility_min" => value(revision, :compatibility_min),
      "compatibility_max" => value(revision, :compatibility_max),
      "author" => value(revision, :author),
      "reason" => value(revision, :reason),
      "receipt" => value(revision, :receipt),
      "facts" => facts |> Enum.sort_by(&value(&1, :fact_id)) |> Enum.map(&digest_fact/1)
    })
  end

  defp digest_fact(fact) do
    %{
      "fact_id" => value(fact, :fact_id),
      "section" => value(fact, :section),
      "value_type" => value(fact, :value_type),
      "typed_value" => value(fact, :typed_value),
      "source_type" => value(fact, :source_type),
      "source_ref" => value(fact, :source_ref),
      "source_status" => value(fact, :source_status),
      "source_observed_at" => DateTime.to_iso8601(value(fact, :source_observed_at)),
      "source_digest" => value(fact, :source_digest),
      "introduced_revision" => value(fact, :introduced_revision),
      "retired_revision" => value(fact, :retired_revision),
      "compatibility_min" => value(fact, :compatibility_min),
      "compatibility_max" => value(fact, :compatibility_max),
      "capability_ref" => value(fact, :capability_ref),
      "promise_ref" => value(fact, :promise_ref),
      "author" => value(fact, :author),
      "reason" => value(fact, :reason),
      "receipt" => value(fact, :receipt)
    }
  end

  defp fact_attributes(%Fact{} = fact) do
    Map.take(fact, [
      :fact_id,
      :section,
      :value_type,
      :typed_value,
      :source_type,
      :source_ref,
      :source_status,
      :source_observed_at,
      :source_digest,
      :introduced_revision,
      :retired_revision,
      :compatibility_min,
      :compatibility_max,
      :capability_ref,
      :promise_ref,
      :author,
      :reason,
      :receipt
    ])
  end

  defp compare_digest(digest, digest), do: :ok
  defp compare_digest(_stored, _calculated), do: {:error, :blueprint_digest_mismatch}

  defp compatible?(value) do
    minimum = value(value, :compatibility_min)
    maximum = value(value, :compatibility_max)

    positive_integer?(minimum) and positive_integer?(maximum) and
      minimum <= @runtime_compatibility and maximum >= @runtime_compatibility
  end

  defp valid_digest?(digest), do: is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
  defp positive_integer?(integer), do: is_integer(integer) and integer > 0
  defp non_empty_string?(string), do: is_binary(string) and String.trim(string) != ""

  defp fetch!(map, key) do
    case get(map, key, :missing) do
      :missing -> raise ArgumentError, "missing Blueprint field #{key}"
      value -> value
    end
  end

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(%_{} = struct, key), do: Map.get(struct, key)
  defp value(map, key), do: get(map, key)

  defp atomize_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      entry -> entry
    end)
  end

  defp unwrap_transaction({:ok, projection}), do: {:ok, projection}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
