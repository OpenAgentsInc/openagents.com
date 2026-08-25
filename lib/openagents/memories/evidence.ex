defmodule OpenAgents.Memories.Evidence do
  @moduledoc """
  What a piece of evidence looks like, in one place.

  Two records cite evidence: a system memory, where the list is required and a
  claim without one is an assertion rather than a memory
  (`OpenAgents.Memories.Memory`), and a challenge, where the list is optional
  and its presence is exactly what separates a challenge that suspends its
  target from one that is merely recorded
  (`OpenAgents.Memories.Admission`).

  The shape is the same on both, so it is defined once. Each entry names a
  `kind` of `receipt`, `memory`, or `url`, a `ref`, and a `digest` — the digest
  so the evidence behind an admitted claim, or behind a suspension, cannot be
  swapped for something else afterwards.

  This is the half that can explain itself to a caller. The other half is a
  check constraint on each table, because a validation the changeset applies is
  an application filter and a second write path reopens it (MEMORY-004).
  """

  import Ecto.Changeset

  @kinds ~w(receipt memory url)
  @maximum 20

  @doc "The kinds of evidence a record may cite."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The most pieces of evidence one record may cite."
  @spec maximum() :: pos_integer()
  def maximum, do: @maximum

  @doc """
  Validates an evidence list, normalising the entries it accepts.

  Absence passes: a caller that requires evidence says so with
  `validate_required/2` first, and the two records differ on that point. An
  empty list never passes, on either record — a list that names nothing is a
  malformed citation rather than an absent one, and reading it as "no evidence"
  is how an evidenced challenge would arrive claiming to be unevidenced.
  """
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(changeset, field) do
    case get_change(changeset, field, get_field(changeset, field)) do
      nil ->
        changeset

      [] ->
        add_error(changeset, field, "must name at least one piece of evidence")

      refs when is_list(refs) and length(refs) > @maximum ->
        add_error(changeset, field, "names more than #{@maximum} pieces of evidence")

      refs when is_list(refs) ->
        if Enum.all?(refs, &ref?/1) do
          put_change(changeset, field, Enum.map(refs, &normalize/1))
        else
          add_error(
            changeset,
            field,
            "each entry needs a kind of #{Enum.join(@kinds, ", ")}, a ref, and a digest"
          )
        end

      _not_a_list ->
        add_error(changeset, field, "must be a list")
    end
  end

  defp ref?(ref) when is_map(ref) do
    kind(ref) in @kinds and present?(entry(ref, "ref", :ref)) and
      present?(entry(ref, "digest", :digest))
  end

  defp ref?(_ref), do: false

  defp normalize(ref) do
    %{
      "kind" => kind(ref),
      "ref" => String.trim(entry(ref, "ref", :ref)),
      "digest" => String.trim(entry(ref, "digest", :digest))
    }
  end

  defp kind(ref), do: entry(ref, "kind", :kind)

  # A caller writes `%{"kind" => …}` over the API and `%{kind: …}` in Elixir,
  # and both mean the same evidence ref.
  defp entry(ref, string_key, atom_key) do
    case Map.get(ref, string_key, Map.get(ref, atom_key)) do
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
