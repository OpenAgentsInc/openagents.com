defmodule OpenAgents.Traces do
  @moduledoc """
  Store and retrieve account-scoped ATIF trace documents.

  ## Binding a trace to an attempt

  A trace may name the `forge_assignments` attempt it is a trajectory of. The
  attempt already records the issue and the repository it was admitted against,
  so naming it is what lets an issue say a trajectory exists without the issue
  holding one.

  The binding is an authority claim, so it is checked rather than trusted: only
  the account that requested the attempt may bind a trace to it. Anybody else
  is refused with `:trace_assignment_forbidden` rather than having the field
  quietly dropped, because a caller that believed it was filing evidence
  against an attempt should not be told it succeeded.

  Binding does not disclose. `traces.visibility` is still the uploader's
  consent and still defaults to `dark`; what an issue's readers may learn from
  a bound trace is decided by `OpenAgents.Issues.TraceDisclosure`, and no rung
  of that ladder returns the document.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Repo
  alias OpenAgents.Traces.Trace

  @maximum_trace_bytes 10_485_760
  @atif_prefixes ["ATIF/1.", "ATIF-v1."]
  @default_visibility "dark"

  @doc "The largest trace body this surface accepts, in bytes."
  def maximum_trace_bytes, do: @maximum_trace_bytes

  @doc """
  Store an ATIF document for an account.

  Re-uploading the same canonical bytes for the same account returns the
  existing trace. A document without an admitted `schema_version` or one that
  exceeds the size ceiling is refused.

  `options` may carry `:visibility`, the tier the uploader consents to, and
  `:assignment_id`, the attempt this trajectory was produced under. The
  assignment must be one this account requested; any other is refused with
  `:trace_assignment_forbidden`.
  """
  def store(%User{} = user, %{} = document), do: store(user, document, [])

  def store(%User{id: user_id} = user, %{} = document, options) do
    canonical = Jason.encode!(document)
    byte_size = byte_size(canonical)

    cond do
      byte_size > @maximum_trace_bytes ->
        {:error, :body_too_large}

      not valid_atif?(document) ->
        {:error, :invalid_atif}

      true ->
        with {:ok, assignment_id} <- requested_assignment(user, options) do
          digest =
            "sha256:" <>
              (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))

          visibility = normalize_visibility(options, document)

          case Repo.get_by(Trace, user_id: user_id, digest: digest) do
            %Trace{} = existing ->
              {:ok, existing, :existing}

            nil ->
              attrs = %{
                user_id: user_id,
                digest: digest,
                visibility: visibility,
                document: document,
                byte_size: byte_size,
                assignment_id: assignment_id
              }

              %Trace{}
              |> Trace.create_changeset(attrs)
              |> Repo.insert()
              |> case do
                {:ok, trace} -> {:ok, trace, :created}
                {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
              end
          end
        end
    end
  end

  def store(_user, _document, _options), do: {:error, :invalid_atif}

  @doc """
  The traces bound to `assignment_ids`, oldest first, grouped by attempt.

  This is a join, not a disclosure: it returns whole rows, and every caller
  that shows one to a reader goes through
  `OpenAgents.Issues.TraceDisclosure`, which decides which fields that reader
  may have. Keeping the two apart is what lets the owner's own surfaces read
  the row while an issue's readers get the schedule.
  """
  @spec for_assignments([binary()]) :: %{binary() => [Trace.t()]}
  def for_assignments([]), do: %{}

  def for_assignments(assignment_ids) when is_list(assignment_ids) do
    Trace
    |> where([trace], trace.assignment_id in ^assignment_ids)
    |> order_by([trace], asc: trace.inserted_at, asc: trace.id)
    |> Repo.all()
    |> Enum.group_by(& &1.assignment_id)
  end

  # Binding a trace to an attempt is a claim about authority, so it is read
  # from the attempt rather than believed from the request. Only the account
  # named as the attempt's requesting principal may bind, which is the same
  # account `WorkDisclosure.link_for_attempt/3` would have raised to `glass`
  # for that attempt — one notion of "whose work this was", not two.
  defp requested_assignment(user, options) do
    case Keyword.get(options, :assignment_id) do
      nil ->
        {:ok, nil}

      id when is_binary(id) ->
        with {:ok, uuid} <- Ecto.UUID.cast(id),
             %Assignment{requesting_principal: %{"type" => "user", "id" => account_id}} <-
               Repo.get(Assignment, uuid),
             true <- account_id == user.id do
          {:ok, uuid}
        else
          _otherwise -> {:error, :trace_assignment_forbidden}
        end

      _invalid ->
        {:error, :trace_assignment_forbidden}
    end
  end

  defp valid_atif?(document) do
    version = Map.get(document, "schema_version") || Map.get(document, :schema_version)

    is_binary(version) and
      String.starts_with?(version, @atif_prefixes)
  end

  defp normalize_visibility(options, document) do
    from_options = Keyword.get(options, :visibility)
    from_document = Map.get(document, "visibility") || Map.get(document, :visibility)
    candidate = from_options || from_document || @default_visibility

    if is_binary(candidate) do
      String.trim(candidate)
    else
      @default_visibility
    end
  end
end
