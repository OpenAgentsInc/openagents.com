defmodule OpenAgentsWeb.ForumTopicLive do
  @moduledoc "One topic thread: its posts, oldest first, with a reply composer."
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum
  alias OpenAgents.Forum.Tips
  alias OpenAgents.Markdown

  # Preset amounts keep tipping one click. Larger amounts go through the API.
  @tip_amounts [100, 1_000]

  def mount(%{"id" => id}, _session, socket) do
    scope = [operator?: OpenAgents.Accounts.admin?(socket.assigns[:current_user])]

    case Forum.fetch_readable_topic(id, scope) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Topic not found")
         |> push_navigate(to: ~p"/forum")}

      {:ok, topic} ->
        {:ok,
         socket
         |> assign(:current_scope, socket.assigns[:current_scope])
         |> assign(:topic, topic)
         |> assign(:posts, Forum.list_posts(topic))
         |> stream(:posts, Forum.list_posts(topic))
         |> assign(:form, to_form(%{"body_text" => ""}, as: :post))}
    end
  end

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
             |> assign(:topic, Forum.get_topic!(socket.assigns.topic.id))
             |> stream(:posts, Forum.list_posts(socket.assigns.topic), reset: true)
             |> assign(:form, to_form(%{"body_text" => ""}, as: :post))}

          {:error, :topic_closed} ->
            {:noreply, put_flash(socket, :error, "This topic is closed")}
        end
    end
  end

  # Tipping pays the author's own destination. A fresh idempotency key per
  # click means a double click cannot pay twice for the same request.
  def handle_event("tip", %{"id" => id, "amount" => amount}, socket) do
    with %{} = user <- current_user(socket),
         {sats, ""} <- Integer.parse(amount),
         post when not is_nil(post) <- Enum.find(socket.assigns.posts, &(&1.id == id)) do
      request = %{
        post: post,
        payer_user: user,
        payer_actor_ref: "user:#{user.id}",
        amount_sats: sats,
        idempotency_key: Ecto.UUID.generate()
      }

      case Tips.tip_post(request) do
        {:ok, intent} ->
          {:noreply, socket |> refresh_posts() |> put_flash(:info, tip_message(intent))}

        {:error, {:payment_failed, intent}} ->
          {:noreply,
           put_flash(socket, :error, "Payment failed: #{intent.failure_code}. Nothing was sent.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, tip_error(reason))}
      end
    else
      _unavailable -> {:noreply, put_flash(socket, :error, "Sign in to tip")}
    end
  end

  def handle_event("toggle_closed", _params, socket) do
    with %{} = user <- current_user(socket),
         true <- OpenAgents.Accounts.admin?(user) do
      new_state = if socket.assigns.topic.state == "open", do: "closed", else: "open"
      {:ok, _} = Forum.set_topic_state(socket.assigns.topic, new_state)

      {:noreply, assign(socket, :topic, Forum.get_topic!(socket.assigns.topic.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Operators only")}
    end
  end

  def handle_event("hide_post", %{"id" => id}, socket) do
    with %{} = user <- current_user(socket),
         true <- OpenAgents.Accounts.admin?(user),
         post <- Enum.find(socket.assigns.posts, &(&1.id == id)),
         {:ok, _} <- Forum.hide_post(post, user) do
      {:noreply,
       socket
       |> assign(:posts, Forum.list_posts(socket.assigns.topic))
       |> stream(:posts, Forum.list_posts(socket.assigns.topic), reset: true)}
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
        <.link navigate={~p"/forum/tips"} class="text-sm text-muted-foreground hover:text-foreground">
          Tips
        </.link>
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

  defp refresh_posts(socket) do
    posts = Forum.list_posts(socket.assigns.topic)

    socket
    |> assign(:posts, posts)
    |> stream(:posts, posts, reset: true)
  end

  defp tip_message(%{counted_sats: 0, exclusion_reason: reason, amount_sats: sats})
       when is_binary(reason) do
    "Sent #{sats} sats. This tip does not change ranking (#{String.replace(reason, "_", " ")})."
  end

  defp tip_message(%{amount_sats: sats}), do: "Sent #{sats} sats"

  defp tip_error(:tipping_disabled), do: "Tipping is not enabled here yet"
  defp tip_error(:no_destination), do: "This author has no tip destination yet"
  defp tip_error(:not_accepting_tips), do: "This author is not accepting tips"
  defp tip_error(:post_not_visible), do: "This post cannot be tipped"

  defp tip_error(:payment_service_unavailable),
    do: "The payment service is unavailable. Nothing was sent."

  defp tip_error(_reason), do: "That tip could not be sent"

  defp tip_amounts, do: @tip_amounts
end
