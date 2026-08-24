defmodule OpenAgents.Labels do
  @moduledoc """
  The Labels context.
  """

  import Ecto.Query, warn: false
  alias OpenAgents.Accounts.User
  alias OpenAgents.Analytics
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository

  alias OpenAgents.Labels.Label

  @doc """
  Subscribes the caller to one repository's labels.

  The message is `{:labels_changed, repository_id}` and carries nothing else,
  so a subscriber re-reads through its own visibility and authorization
  predicates -- a viewer without write access is offered no picker at all.
  """
  def subscribe_labels(repository_id) when is_binary(repository_id),
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, labels_topic(repository_id))

  @doc """
  Announces that one repository's labels moved.

  Called after the owning write commits, never inside it: a subscriber re-reads
  the moment it hears, and an announcement from inside an open transaction
  hands it the repository as it was.

  Attaching a label to an issue is not one of these writes. That goes through
  `Issues.update_issue/3`, which announces on the issue topic; this one is for
  the label set a repository offers.
  """
  def broadcast_labels(repository_id) when is_binary(repository_id) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      labels_topic(repository_id),
      {:labels_changed, repository_id}
    )
  end

  defp labels_topic(repository_id), do: "labels:" <> repository_id

  @doc """
  Returns the list of labels.

  ## Examples

      iex> list_labels()
      [%Label{}, ...]

  """
  def list_labels(%Repository{id: repository_id}) do
    Label
    |> where(repository_id: ^repository_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Gets a single label.

  Raises `Ecto.NoResultsError` if the Label does not exist.

  ## Examples

      iex> get_label!(123)
      %Label{}

      iex> get_label!(456)
      ** (Ecto.NoResultsError)

  """
  def get_label!(%Repository{id: repository_id}, id) do
    Repo.get_by!(Label, id: id, repository_id: repository_id)
  end

  def get_label_by_name!(%Repository{id: repository_id}, name) when is_binary(name) do
    Repo.get_by!(Label, repository_id: repository_id, name: URI.decode(name))
  end

  @doc """
  Returns the named label, creating it with a generated colour when it is
  missing, the way GitHub does when a script adds a label an issue has never
  worn.
  """
  def get_or_create_label_by_name(%Repository{} = repository, name, actor \\ nil)
      when is_binary(name) do
    decoded = URI.decode(name)

    case Repo.get_by(Label, repository_id: repository.id, name: decoded) do
      %Label{} = label ->
        {:ok, label}

      nil ->
        case create_label(repository, %{"name" => decoded, "color" => generated_color()}, actor) do
          {:error, %Ecto.Changeset{}} = error ->
            # Another request can create the same label after the read above.
            # Return that committed row instead of turning a harmless race
            # into a 500 response.
            case Repo.get_by(Label, repository_id: repository.id, name: decoded) do
              %Label{} = label -> {:ok, label}
              nil -> error
            end

          result ->
            result
        end
    end
  end

  defp generated_color, do: Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

  @doc """
  Creates a label.

  ## Examples

      iex> create_label(%{field: value})
      {:ok, %Label{}}

      iex> create_label(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_label(%Repository{} = repository, attrs, actor \\ nil)
      when is_nil(actor) or is_struct(actor, User) do
    attrs =
      attrs
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
      |> Map.put("repository_id", repository.id)

    %Label{}
    |> Label.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, label} ->
        Analytics.capture("label_created", actor_distinct_id(actor), %{
          "owner" => repository.owner,
          "repo" => repository.name
        })

        broadcast_labels(repository.id)
        {:ok, label}

      result ->
        result
    end
  end

  defp actor_distinct_id(nil), do: Analytics.system_distinct_id("api")
  defp actor_distinct_id(%User{} = actor), do: Analytics.distinct_id(actor)

  @doc """
  Updates a label.

  ## Examples

      iex> update_label(label, %{field: new_value})
      {:ok, %Label{}}

      iex> update_label(label, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_label(%Label{} = label, attrs) do
    attrs = Map.drop(attrs, [:repository_id, "repository_id"])

    label
    |> Label.changeset(attrs)
    |> Repo.update()
    |> announce()
  end

  @doc """
  Deletes a label.

  ## Examples

      iex> delete_label(label)
      {:ok, %Label{}}

      iex> delete_label(label)
      {:error, %Ecto.Changeset{}}

  """
  def delete_label(%Label{} = label) do
    label
    |> Repo.delete()
    |> announce()
  end

  defp announce({:ok, %Label{} = label} = result) do
    broadcast_labels(label.repository_id)
    result
  end

  defp announce(result), do: result

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking label changes.

  ## Examples

      iex> change_label(label)
      %Ecto.Changeset{data: %Label{}}

  """
  def change_label(%Label{} = label, attrs \\ %{}) do
    Label.changeset(label, attrs)
  end
end
