defmodule OpenAgentsWeb.ForumTopicLive do
  @moduledoc """
  One topic: its posts, oldest first, with a reply composer.

  The page follows the topic rather than showing it as it stood when you
  opened it. A reply written anywhere -- in another browser, through the API,
  or by an agent -- arrives without a reload, and so does a post an operator
  hides and a topic they close.

  The announcement carries a topic id and nothing else (#154), so the page
  re-reads through `Forum.fetch_readable_topic/2` with the same scope it
  mounted under. A board that stops being readable takes its topic with it,
  and a post keeps the identity it was written under: a migrated post's byline
  is its legacy name until a claim binds it, on a refresh no less than on a
  mount.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum
  # Tipping is commented out until the payment service is enabled here.
  # alias OpenAgents.Forum.Tips
  alias OpenAgents.Markdown
  alias OpenAgentsWeb.LiveRefresh
  alias OpenAgentsWeb.OG

  # Preset amounts keep tipping one click. Larger amounts go through the API.
  # @tip_amounts [100, 1_000]

  def mount(%{"id" => id}, _session, socket) do
    scope = [operator?: OpenAgents.Accounts.admin?(socket.assigns[:current_user])]

    case Forum.fetch_readable_topic(id, scope) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Topic not found")
         |> push_navigate(to: ~p"/forum")}

      {:ok, topic} ->
        if connected?(socket), do: Forum.subscribe_posts()

        posts = Forum.list_posts(topic)

        {:ok,
         socket
         |> LiveRefresh.init()
         |> assign(:current_scope, socket.assigns[:current_scope])
         |> assign(:read_scope, scope)
         |> assign(:topic, topic)
         |> assign(:page_title, topic.title)
         |> assign(:og, topic_og(topic, posts))
         |> assign(:posts, posts)
         |> stream(:posts, posts)
         |> assign(:form, to_form(%{"body_text" => ""}, as: :post))}
    end
  end

  # Every post on the forum announces itself on one topic, so a page reading
  # one topic can ignore the rest by id alone rather than by reading to find
  # out. A busy board costs this page nothing.
  def handle_info({:forum_posts_changed, topic_id}, socket) do
    if topic_id == socket.assigns.topic.id,
      do: {:noreply, LiveRefresh.mark_stale(socket, :posts, &refresh_panel/2)},
      else: {:noreply, socket}
  end

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  def handle_event("reply", %{"post" => %{"body_text" => body_text}}, socket)
      when body_text == "" or is_nil(body_text) do
    {:noreply, put_flash(socket, :error, "Write something first")}
  end

  def handle_event("reply", %{"post" => params}, socket) do
    user = current_user(socket)

    case user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to post")}

      user ->
        attrs = %{
          body_text: params["body_text"],
          actor_ref: "user:#{user.id}",
          actor_display_name: user.github_name || user.github_login,
          actor_slug: user.github_login,
          actor_is_agent: false,
          idempotency_key: Ecto.UUID.generate()
        }

        case Forum.create_post(socket.assigns.topic, attrs) do
          {:ok, _post} ->
            {:noreply,
             socket
             |> refresh_panel(:posts)
             |> assign(:form, to_form(%{"body_text" => ""}, as: :post))}

          {:error, :topic_closed} ->
            {:noreply, put_flash(socket, :error, "This topic is closed")}
        end
    end
  end

  # Tipping pays the author's own destination. A fresh idempotency key per
  # click means a double click cannot pay twice for the same request.
  #
  # Commented out until the payment service is enabled here: with it disabled,
  # every click answered "Tipping is not enabled here yet".
  #
  # def handle_event("tip", %{"id" => id, "amount" => amount}, socket) do
  #   with %{} = user <- current_user(socket),
  #        {sats, ""} <- Integer.parse(amount),
  #        post when not is_nil(post) <- Enum.find(socket.assigns.posts, &(&1.id == id)) do
  #     request = %{
  #       post: post,
  #       payer_user: user,
  #       payer_actor_ref: "user:#{user.id}",
  #       amount_sats: sats,
  #       idempotency_key: Ecto.UUID.generate()
  #     }
  #
  #     case Tips.tip_post(request) do
  #       {:ok, intent} ->
  #         {:noreply, socket |> refresh_panel(:posts) |> put_flash(:info, tip_message(intent))}
  #
  #       {:error, {:payment_failed, intent}} ->
  #         {:noreply,
  #          put_flash(socket, :error, "Payment failed: #{intent.failure_code}. Nothing was sent.")}
  #
  #       {:error, reason} ->
  #         {:noreply, put_flash(socket, :error, tip_error(reason))}
  #     end
  #   else
  #     _unavailable -> {:noreply, put_flash(socket, :error, "Sign in to tip")}
  #   end
  # end

  def handle_event("toggle_closed", _params, socket) do
    with %{} = user <- current_user(socket),
         true <- OpenAgents.Accounts.admin?(user) do
      new_state = if socket.assigns.topic.state == "open", do: "closed", else: "open"
      {:ok, _} = Forum.set_topic_state(socket.assigns.topic, new_state)

      {:noreply, refresh_panel(socket, :posts)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Operators only")}
    end
  end

  def handle_event("hide_post", %{"id" => id}, socket) do
    with %{} = user <- current_user(socket),
         true <- OpenAgents.Accounts.admin?(user),
         post <- Enum.find(socket.assigns.posts, &(&1.id == id)),
         {:ok, _} <- Forum.hide_post(post, user) do
      {:noreply, refresh_panel(socket, :posts)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Operators only")}
    end
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
        <h1 class="text-2xl font-bold">{@topic.title}</h1>
        <%!-- Tipping is commented out until the payment service is enabled here.
        <.link navigate={~p"/forum/tips"} class="text-sm text-muted-foreground hover:text-foreground">
          Tips
        </.link>
        --%>
        <%= if @topic.state == "closed" do %>
          <span class="badge" data-variant="dim">closed</span>
        <% end %>
        <%= if OpenAgents.Accounts.admin?(@current_user) do %>
          <button class="btn" data-variant="ghost" data-size="sm" phx-click="toggle_closed">
            {if @topic.state == "open", do: "Close topic", else: "Reopen topic"}
          </button>
        <% end %>
      </div>

      <div id="posts" phx-update="stream" class="space-y-4">
        <div id="posts-empty" class="hidden only:block text-sm text-muted-foreground">
          No posts yet.
        </div>
        <div :for={{id, post} <- @streams.posts} id={id} class="card !m-0">
          <header class="flex items-center justify-between mb-2">
            <span class="font-semibold text-sm">{post.actor_display_name}</span>
            <span class="flex items-center gap-2">
              <%= if OpenAgents.Accounts.admin?(@current_user) do %>
                <button
                  class="btn"
                  data-variant="ghost"
                  data-size="sm"
                  phx-click="hide_post"
                  phx-value-id={post.id}
                >
                  Hide
                </button>
              <% end %>
              <%= if post.tip_count > 0 do %>
                <span class="badge" data-variant="dim" title="Settled tips">
                  {post.tip_sats_total} sats
                </span>
              <% end %>
              <span class="text-xs text-muted-foreground"># {post.post_number}</span>
            </span>
          </header>
          <div class="prose prose-sm dark:prose-invert max-w-none">
            {Markdown.to_html(post.body_text)}
          </div>
          <%!-- Tipping is commented out until the payment service is enabled here.
          <footer :if={@current_user} class="flex items-center gap-2 mt-3">
            <span class="text-xs text-muted-foreground">Tip the author</span>
            <button
              :for={amount <- tip_amounts()}
              class="btn"
              data-variant="ghost"
              data-size="sm"
              phx-click="tip"
              phx-value-id={post.id}
              phx-value-amount={amount}
            >
              {amount} sats
            </button>
          </footer>
          --%>
        </div>
      </div>

      <%= if @topic.state == "open" do %>
        <.form for={@form} id="reply-form" phx-submit="reply" class="card !mx-0 !mt-6">
          <.input field={@form[:body_text]} label="Reply" type="textarea" rows={4} required />
          <footer class="flex justify-end mt-2">
            <.button type="submit" variant={:primary}>Post reply</.button>
          </footer>
        </.form>
      <% end %>
    </Layouts.app>
    """
  end

  defp current_user(socket), do: socket.assigns[:current_user]

  defp topic_og(topic, posts) do
    forum = Forum.get_forum!(topic.forum_id)
    summary = with %{body_text: body} <- List.first(posts), do: body

    OG.meta(OG.forum_topic(forum, topic, summary: summary))
  end

  # The one re-read this page has, whether the write was made here or heard
  # about. It goes back through the same authorized read that filled the page
  # at mount, so a topic whose board has stopped being readable leaves rather
  # than staying open on a scope it no longer belongs to.
  defp refresh_panel(socket, :posts) do
    case Forum.fetch_readable_topic(socket.assigns.topic.id, socket.assigns.read_scope) do
      {:ok, topic} ->
        posts = Forum.list_posts(topic)

        socket
        |> assign(:topic, topic)
        |> assign(:posts, posts)
        |> stream(:posts, posts, reset: true)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Topic not found")
        |> push_navigate(to: ~p"/forum")
    end
  end

  # Tipping helpers, commented out with the tip event above.
  #
  # defp tip_message(%{counted_sats: 0, exclusion_reason: reason, amount_sats: sats})
  #      when is_binary(reason) do
  #   "Sent #{sats} sats. This tip does not change ranking (#{String.replace(reason, "_", " ")})."
  # end
  #
  # defp tip_message(%{amount_sats: sats}), do: "Sent #{sats} sats"
  #
  # defp tip_error(:tipping_disabled), do: "Tipping is not enabled here yet"
  # defp tip_error(:no_destination), do: "This author has no tip destination yet"
  # defp tip_error(:not_accepting_tips), do: "This author is not accepting tips"
  # defp tip_error(:post_not_visible), do: "This post cannot be tipped"
  #
  # defp tip_error(:payment_service_unavailable),
  #   do: "The payment service is unavailable. Nothing was sent."
  #
  # defp tip_error(_reason), do: "That tip could not be sent"
  #
  # defp tip_amounts, do: @tip_amounts
end
