defmodule OpenAgentsWeb.ForumBoardLive do
  @moduledoc "One forum board: its topics, newest activity first, and a composer."
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum

  def mount(%{"slug" => slug}, _session, socket) do
    scope = [operator?: OpenAgents.Accounts.admin?(socket.assigns[:current_user])]

    case Forum.fetch_readable_forum_by_slug(slug, scope) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Board not found")
         |> push_navigate(to: ~p"/forum")}

      {:ok, forum} ->
        {:ok,
         socket
         |> assign(:current_scope, socket.assigns[:current_scope])
         |> assign(:forum, forum)
         |> assign(:topics, Forum.list_topics(forum))
         |> stream(:topics, Forum.list_topics(forum))
         |> assign(:form, to_form(%{"title" => "", "body_text" => ""}, as: :topic))}
    end
  end

  def handle_event("new_topic", %{"topic" => params}, socket) do
    user = socket.assigns[:current_user]

    case user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to post")}

      user ->
        attrs = %{
          title: params["title"],
          slug: slugify(params["title"]),
          body_text: params["body_text"],
          idempotency_key: Ecto.UUID.generate(),
          actor_ref: "user:#{user.id}",
          actor_display_name: user.github_name || user.github_login,
          actor_slug: user.github_login,
          actor_is_agent: false
        }

        case Forum.create_topic(socket.assigns.forum, attrs) do
          {:ok, _topic} ->
            {:noreply,
             socket
             |> stream(:topics, Forum.list_topics(socket.assigns.forum), reset: true)
             |> assign(:form, to_form(%{"title" => "", "body_text" => ""}, as: :topic))
             |> put_flash(:info, "Topic created")}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  defp slugify(nil), do: nil

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <div class="flex items-center gap-2 mb-4">
        <.link navigate={~p"/forum"} class="text-sm text-muted-foreground hover:text-foreground">
          Forum
        </.link>
        <span class="text-muted-foreground">/</span>
        <h1 class="text-2xl font-bold">{@forum.title}</h1>
      </div>

      <.form for={@form} id="new-topic-form" phx-submit="new_topic" class="card !mx-0 !mt-0 mb-6">
        <.input field={@form[:title]} label="Title" required />
        <.input field={@form[:body_text]} label="First post" type="textarea" rows={4} required />
        <footer class="flex justify-end mt-2">
          <.button type="submit" variant={:primary}>Start topic</.button>
        </footer>
      </.form>

      <div id="topics" phx-update="stream">
        <div id="topics-empty" class="hidden only:block text-sm text-muted-foreground">
          No topics yet.
        </div>
        <div :for={{id, topic} <- @streams.topics} id={id} class="card !m-0 mb-3">
          <.link navigate={~p"/forum/t/#{topic.id}"} class="text-lg font-semibold hover:underline">
            {topic.title}
          </.link>
          <div class="flex items-center gap-3 text-sm text-muted-foreground mt-1">
            <span>{topic.actor_display_name}</span>
            <span>{topic.post_count} posts</span>
            <span>{Calendar.strftime(topic.updated_at, "%b %d, %Y")}</span>
            <%= if topic.pin_state == "pinned" do %>
              <span class="badge" data-variant="dim">pinned</span>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
