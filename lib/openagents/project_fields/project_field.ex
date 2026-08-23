defmodule OpenAgents.ProjectFields.ProjectField do
  @moduledoc """
  One stored column of a project board.

  A field's `name` is the key an item's stored `values` map is written under, so
  the name has to be unique within a project and stable across a rename. A
  `single_select` field additionally carries option identifiers, and an item
  stores the identifier rather than the label, so relabelling an option never
  rewrites the items that chose it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @data_types ~w(text number date single_select promise_state)
  @option_data_types ~w(single_select promise_state)
  @max_options 100

  @doc "The data types a project field can declare."
  def data_types, do: @data_types

  @doc "Whether `data_type` carries a bounded set of options."
  def options?(data_type), do: data_type in @option_data_types

  schema "project_fields" do
    field :name, :string
    field :data_type, :string
    field :options, :map
    field :project_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc """
  The stable identifiers a field's options offer, in declaration order.

  A plain string option is its own identifier: the label is the identifier, and
  relabelling it is a new option. An option written as `%{"id" =>, "name" =>}`
  keeps its identifier when the label changes, which is what makes a rename
  non-destructive for the items that already chose it.
  """
  def option_ids(%__MODULE__{options: %{"values" => values}}) when is_list(values),
    do: Enum.map(values, &option_id/1)

  def option_ids(%__MODULE__{}), do: []

  @doc "The identifier of one declared option."
  def option_id(value) when is_binary(value), do: value
  def option_id(%{"id" => id}) when is_binary(id), do: id
  def option_id(_value), do: nil

  @doc false
  def changeset(project_field, attrs) do
    project_field
    |> cast(attrs, [:name, :data_type, :options, :project_id])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name, :data_type, :project_id])
    |> validate_length(:name, max: 100)
    |> validate_inclusion(:data_type, @data_types)
    |> validate_options()
    |> unique_constraint(:name,
      name: :project_fields_project_id_name_index,
      message: "has already been taken on this project"
    )
    |> check_constraint(:data_type, name: :project_fields_data_type_check, message: "is invalid")
    |> foreign_key_constraint(:project_id)
  end

  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(name), do: name

  defp validate_options(changeset) do
    data_type = get_field(changeset, :data_type)
    options = get_field(changeset, :options)

    cond do
      data_type not in @data_types ->
        changeset

      not options?(data_type) ->
        validate_no_options(changeset, options)

      true ->
        validate_option_values(changeset, options)
    end
  end

  defp validate_no_options(changeset, options) when options in [nil, %{}], do: changeset

  defp validate_no_options(changeset, _options),
    do: add_error(changeset, :options, "are not supported for this data type")

  defp validate_option_values(changeset, %{"values" => values})
       when is_list(values) and values != [] do
    cond do
      length(values) > @max_options ->
        add_error(changeset, :options, "carry at most #{@max_options} values")

      Enum.any?(values, &is_nil(option_id(&1))) ->
        add_error(
          changeset,
          :options,
          ~s(each value is a name, or an object with a string "id" and "name")
        )

      Enum.any?(values, &blank_option?/1) ->
        add_error(changeset, :options, "cannot carry a blank value")

      duplicate_ids?(values) ->
        add_error(changeset, :options, "cannot repeat an identifier")

      true ->
        put_change(changeset, :options, %{"values" => Enum.map(values, &normalize_option/1)})
    end
  end

  defp validate_option_values(changeset, _options),
    do:
      add_error(
        changeset,
        :options,
        ~s(must carry a non-empty "values" list for this data type)
      )

  defp blank_option?(value) do
    id = option_id(value)
    name = option_name(value)

    String.trim(id) == "" or not is_binary(name) or String.trim(name) == ""
  end

  defp duplicate_ids?(values) do
    ids = Enum.map(values, &option_id/1)
    length(Enum.uniq(ids)) != length(ids)
  end

  defp normalize_option(value) when is_binary(value), do: String.trim(value)

  defp normalize_option(%{} = value),
    do: %{"id" => String.trim(option_id(value)), "name" => String.trim(option_name(value))}

  defp option_name(value) when is_binary(value), do: value
  defp option_name(%{"name" => name}), do: name
  defp option_name(_value), do: nil
end
