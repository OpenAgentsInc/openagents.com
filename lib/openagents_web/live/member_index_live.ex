defmodule OpenAgentsWeb.MemberIndexLive do
  @moduledoc """
  Repository members, managed by owners.

  Membership is what admits a person to private repositories, issue triage,
  and Git push, so the surface stays owner-only and every change flows through
  `OpenAgents.Repositories.add_member_by_login/4` and its siblings, which
  write audit records. The last owner cannot be demoted or removed; that rule
  lives in the context and is enforced again here for a readable error.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Repositories

  @roles ~w(owner maintainer contributor viewer)

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    user = socket.assigns.current_user

    # A non-member gets the same quiet bounce as a nonexistent repository:
    # member administration never confirms who has access to what.
    repository =
      try do
        Repositories.get_writable_by_path!(owner, repo, user)
      rescue
        Ecto.NoResultsError -> nil
      end

    cond do
      is_nil(repository) ->
        {:ok,
         socket
         |> put_flash(:error, "You do not have access to that repository.")
         |> redirect(to: ~p"/")}

      not Repositories.owner?(repository, user) ->
        {:ok,
         socket
         |> assign(:current_scope, socket.assigns[:current_scope])
         |> put_flash(:error, "Only repository owners can manage members.")
         |> redirect(to: ~p"/#{owner}/#{repo}/issues")}

      true ->
        {:ok,
         socket
         |> assign(:current_scope, socket.assigns[:current_scope])
         |> assign(:owner, owner)
         |> assign(:repo, repo)
         |> assign(:repository, repository)
         |> assign(:roles, @roles)
         |> assign(
           :member_form,
           to_form(%{"login" => "", "role" => "contributor"}, as: :member)
         )
         |> stream(:members, Repositories.list_members(repository),
           dom_id: &"member-#{&1.user_id}",
           reset: true
         )}
    end
  end

  def handle_event("add_member", %{"member" => params}, socket) do
    login = params["login"] || ""
    role = params["role"] || "contributor"

    case Repositories.add_member_by_login(
           socket.assigns.repository,
           socket.assigns.current_user,
           login,
           role
         ) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> assign(
           :member_form,
           to_form(%{"login" => "", "role" => "contributor"}, as: :member)
         )
         |> reload()
         |> put_flash(:info, "@#{login} added as #{role}")}

      {:error, :unknown_user} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No OpenAgents account found for @#{login}. They need to sign in once first."
         )}

      {:error, :forbidden} ->
        {:noreply, owner_required(socket)}
    end
  end

  def handle_event("change_role", %{"user_id" => user_id, "role" => role}, socket)
      when role in @roles do
    case Repositories.change_member_role(
           socket.assigns.repository,
           socket.assigns.current_user,
           user_id,
           role
         ) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Role updated to #{role}")}

      {:error, :last_owner} ->
        {:noreply, put_flash(socket, :error, "A repository must keep at least one owner.")}

      {:error, :forbidden} ->
        {:noreply, owner_required(socket)}

      {:error, :unknown_member} ->
        {:noreply, put_flash(socket, :error, "That repository member no longer exists.")}
    end
  end

  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    case Repositories.remove_member(
           socket.assigns.repository,
           socket.assigns.current_user,
           user_id
         ) do
      :ok ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Member removed")}

      {:error, :last_owner} ->
        {:noreply, put_flash(socket, :error, "A repository must keep at least one owner.")}

      {:error, :forbidden} ->
        {:noreply, owner_required(socket)}

      {:error, :unknown_member} ->
        {:noreply, put_flash(socket, :error, "That repository member no longer exists.")}
    end
  end

  def handle_event(_unsupported_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That membership action is not available.")}
  end

  defp owner_required(socket) do
    put_flash(socket, :error, "Only repository owners can manage members.")
  end

  defp reload(socket) do
    socket
    |> stream(
      :members,
      Repositories.list_members(socket.assigns.repository),
      dom_id: &"member-#{&1.user_id}",
      reset: true
    )
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Members"
    >
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Members</h1>
      </div>

      <.form for={@member_form} phx-submit="add_member" id="add-member-form">
        <div class="grid grid-cols-1 md:grid-cols-[2fr_1fr_auto] gap-4 items-end card !m-0 mb-6 p-4">
          <.input
            field={@member_form[:login]}
            label="GitHub login"
            placeholder="their-github-login"
            required
          />
          <.input
            field={@member_form[:role]}
            type="select"
            label="Role"
            options={Enum.map(@roles, &{String.capitalize(&1), &1})}
          />
          <.button type="submit" variant={:primary}>Add member</.button>
        </div>
      </.form>

      <div id="members" phx-update="stream">
        <div
          :for={{id, membership} <- @streams.members}
          id={id}
          class="flex items-center justify-between border-b border-border py-3"
        >
          <div class="flex items-center gap-3 min-w-0">
            <img
              src={membership.user.github_avatar_url}
              alt=""
              class="size-8 rounded-full"
              loading="lazy"
            />
            <span class="font-medium truncate">{membership.user.github_login}</span>
          </div>

          <div class="flex items-center gap-2">
            <form
              id={"member-role-form-#{id}"}
              phx-change="change_role"
              class="flex items-center gap-2"
            >
              <input type="hidden" name="user_id" value={membership.user_id} />
              <.input
                name="role"
                type="select"
                aria-label={"Role for #{membership.user.github_login}"}
                class="input !py-1.5"
                data-member-role={membership.role}
                options={Enum.map(@roles, &{String.capitalize(&1), &1})}
                value={membership.role}
              />
            </form>
            <button
              phx-click="remove_member"
              phx-value-user-id={membership.user_id}
              class="btn"
              data-variant="ghost"
              data-size="sm"
              data-tone="danger"
              aria-label={"Remove #{membership.user.github_login}"}
            >
              Remove
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
