defmodule OpenAgentsWeb.ForumBoardLive do
  @moduledoc """
  One forum board: its topics, newest activity first, and a composer.

  The board reorders itself. A topic started or replied to anywhere moves to
  the top with its reply count, and a topic an operator pins moves above the
  rest, none of it needing a reload.

  The announcement carries a topic id and nothing else (#154), and a board
  cannot tell from an id whether the topic is one of its own without reading,
  so it re-reads its own page -- through `fetch_readable_forum_by_slug/2` with
  the scope it mounted under, which is what makes a board that has stopped
  being readable leave rather than keep serving its topics. The read is one
  bounded page, and a burst of replies costs one of them.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum
  alias OpenAgentsWeb.LiveRefresh
  alias OpenAgentsWeb.OG

  def mount(%{"slug" => slug}, _session, socket) do
    scope = [operator?: OpenAgents.Accounts.admin?(socket.assigns[:current_user])]

    case Forum.fetch_readable_forum_by_slug(slug, scope) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Board not found")
         |> push_navigate(to: ~p"/forum")}

      {:ok, forum} ->
        if connected?(socket), do: Forum.subscribe_posts()

        {:ok,
         socket
         |> LiveRefresh.init()
         |> assign(:current_scope, socket.assigns[:current_scope])
         |> assign(:read_scope, scope)
         |> assign(:forum, forum)
         |> assign(:page_title, forum.title)
         |> assign(:og, OG.meta(OG.forum_board(forum)))
         |> stream(:topics, ranked_topics(forum))
         |> assign(:form, to_form(%{"title" => "", "body_text" => ""}, as: :topic))}
    end
  end

  def handle_info({:forum_posts_changed, _topic_id}, socket),
    do: {:noreply, LiveRefresh.mark_stale(socket, :topics, &refresh_panel/2)}

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

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
             |> refresh_panel(:topics)
             |> assign(:form, to_form(%{"title" => "", "body_text" => ""}, as: :topic))
             |> put_flash(:info, "Topic created")}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  # The one re-read this page has, whether the write was made here or heard
  # about. The board is re-read too, not only its topics: its own counters are
  # rendered beside them, and a board that has stopped being readable should
  # take its topics with it rather than keep serving a page it would now
  # refuse.
  defp refresh_panel(socket, :topics) do
    case Forum.fetch_readable_forum_by_slug(socket.assigns.forum.slug, socket.assigns.read_scope) do
      {:ok, forum} ->
        socket
        |> assign(:forum, forum)
        |> stream(:topics, ranked_topics(forum), reset: true)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Board not found")
        |> push_navigate(to: ~p"/forum")
    end
  end

  # Settled tips are one bounded, decaying ranking signal beside recency.
  # Ordering reads stored totals, so it works whether or not tips are enabled.
  defp ranked_topics(forum), do: Forum.list_topics(forum, order: :ranked)

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
            <%= if topic.tip_count > 0 do %>
              <span class="badge" data-variant="dim">{topic.tip_sats_total} sats</span>
            <% end %>
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
