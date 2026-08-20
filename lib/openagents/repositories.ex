defmodule OpenAgents.Repositories do
  @moduledoc "Canonical repository identity and membership authorization."

  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.{Membership, Repository}

  @initial_owner "OpenAgentsInc"
  @initial_name "openagents.com"
  @writable_roles ~w(owner maintainer contributor)

  def initial_path, do: {@initial_owner, @initial_name}

  def initial_repository! do
    get_by_path!(@initial_owner, @initial_name)
  end

  def get_by_path!(owner, name) when is_binary(owner) and is_binary(name) do
    Repo.one!(
      from repository in Repository,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(name)
    )
  end

  def get_public_by_path!(owner, name) when is_binary(owner) and is_binary(name) do
    Repo.one!(
      from repository in Repository,
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(name) and repository.visibility == "public"
    )
  end

  def get_writable_by_path!(owner, name, %User{id: user_id}) do
    Repo.one!(
      from repository in Repository,
        join: membership in Membership,
        on:
          membership.repository_id == repository.id and membership.user_id == ^user_id and
            membership.role in ^@writable_roles,
        join: user in User,
        on: user.id == membership.user_id and user.status == "active",
        where:
          repository.owner_key == ^String.downcase(owner) and
            repository.name_key == ^String.downcase(name)
    )
  end

  def create_repository(attrs) do
    %Repository{}
    |> Repository.changeset(attrs)
    |> Repo.insert()
  end

  def add_member(%Repository{} = repository, %User{} = user, role \\ "contributor") do
    %Membership{}
    |> Membership.changeset(%{repository_id: repository.id, user_id: user.id, role: role})
    |> Repo.insert(
      on_conflict: {:replace, [:role, :updated_at]},
      conflict_target: [:repository_id, :user_id],
      returning: true
    )
  end

  def ensure_initial_membership(%User{} = user) do
    add_member(initial_repository!(), user)
  end

  def writable?(%Repository{id: repository_id}, %User{id: user_id}) do
    Repo.exists?(
      from membership in Membership,
        join: user in User,
        on: user.id == membership.user_id and user.status == "active",
        where:
          membership.repository_id == ^repository_id and membership.user_id == ^user_id and
            membership.role in ^@writable_roles
    )
  end

  def list_assignable_users(%Repository{id: repository_id}) do
    Repo.all(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          membership.repository_id == ^repository_id and
            membership.role in ^@writable_roles and user.status == "active",
        order_by: [asc: fragment("lower(?)", user.github_login)]
    )
  end

  def get_assignable_user_by_login!(%Repository{id: repository_id}, login)
      when is_binary(login) do
    Repo.one!(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          membership.repository_id == ^repository_id and
            membership.role in ^@writable_roles and user.status == "active" and
            fragment("lower(?)", user.github_login) == ^String.downcase(URI.decode(login))
    )
  end
end
