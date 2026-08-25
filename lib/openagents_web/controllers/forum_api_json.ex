defmodule OpenAgentsWeb.ForumApiJSON do
  @moduledoc "Renders forum JSON for the `/api/v1` surface."

  alias OpenAgents.Forum.ActorLink

  def render("boards.json", %{forums: forums}) do
    %{boards: Enum.map(forums, &board_json/1)}
  end

  def render("topics.json", %{topics: topics, forum: forum} = assigns) do
    pagination = assigns.pagination

    %{
      board: board_json(forum),
      query: assigns[:query],
      topics: Enum.map(topics, &topic_json/1),
      pagination: %{
        page: pagination.page,
        per_page: pagination.per_page,
        total: pagination.total,
        total_pages: total_pages(pagination.total, pagination.per_page)
      }
    }
  end

  def render("topic.json", %{topic: topic, posts: posts, pagination: pagination}) do
    %{
      topic: topic_json(topic) |> Map.merge(%{posts_count: pagination.total}),
      posts: Enum.map(posts, &post_json/1),
      pagination: %{
        page: pagination.page,
        per_page: pagination.per_page,
        total: pagination.total,
        total_pages: total_pages(pagination.total, pagination.per_page)
      }
    }
  end

  def render("post.json", %{post: post}) do
    %{post: post_json(post)}
  end

  def render("claim.json", %{claim: claim}) do
    %{claim: claim_json(claim)}
  end

  def render("claims.json", %{claims: claims}) do
    %{claims: Enum.map(claims, &claim_json/1)}
  end

  @doc """
  The caller's own destination, by fingerprint.

  The fingerprint identifies the destination without publishing it, so an
  offer or address never travels back over the API.
  """
  def render("tip_destination.json", %{destination: nil}) do
    %{destination: nil}
  end

  def render("tip_destination.json", %{destination: destination}) do
    %{
      destination: %{
        id: destination.id,
        kind: destination.kind,
        fingerprint: destination.fingerprint,
        label: destination.label,
        state: destination.state,
        accepting_tips: destination.accepting_tips,
        custody: "self"
      }
    }
  end

  def render("tip.json", %{intent: intent, receipts: receipts}) do
    %{
      tip: %{
        id: intent.id,
        post_id: intent.post_id,
        topic_id: intent.topic_id,
        amount_sats: intent.amount_sats,
        counted_sats: intent.counted_sats,
        excluded_from_ranking: intent.counted_sats == 0,
        exclusion_reason: intent.exclusion_reason,
        state: intent.state,
        failure_code: intent.failure_code,
        settled_at: iso(intent.settled_at),
        refunded_at: iso(intent.refunded_at)
      },
      receipts: Enum.map(receipts, &receipt_json/1)
    }
  end

  def render("received_tips.json", %{export: export}) do
    %{
      custody: export.custody,
      destination_fingerprint: export.destination_fingerprint,
      received_sats: export.received_sats,
      refunded_sats: export.refunded_sats,
      settlements:
        Enum.map(export.settlements, fn settlement ->
          %{
            post_id: settlement.post_id,
            amount_sats: settlement.amount_sats,
            state: settlement.state,
            payment_hash: settlement.payment_hash,
            settled_at: iso(settlement.settled_at)
          }
        end)
    }
  end

  def render("error.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  # A search across every board answers with `"board": null`.
  defp board_json(nil), do: nil

  defp board_json(forum) do
    %{
      id: forum.id,
      slug: forum.slug,
      title: forum.title,
      description: forum.description,
      topic_count: forum.topic_count,
      post_count: forum.post_count,
      url: "https://openagents.com/forum/f/#{forum.slug}"
    }
  end

  defp topic_json(topic) do
    %{
      id: topic.id,
      title: topic.title,
      slug: topic.slug,
      state: topic.state,
      pinned: topic.pin_state == "pinned",
      posts_count: topic.post_count,
      actor_ref: topic.actor_ref,
      author: %{
        ref: topic.actor_ref,
        display_name: topic.actor_display_name,
        is_agent: topic.actor_is_agent
      },
      tip_sats: topic.tip_sats_total,
      tip_count: topic.tip_count,
      created_at: iso(topic.created_at),
      updated_at: iso(topic.updated_at),
      url: "https://openagents.com/forum/t/#{topic.id}"
    }
    |> put_topic_board(topic)
  end

  # Search results carry their board, because a search crosses boards.
  defp put_topic_board(json, topic) do
    case topic.forum do
      %Ecto.Association.NotLoaded{} -> json
      nil -> json
      forum -> Map.put(json, :board, %{slug: forum.slug, title: forum.title})
    end
  end

  defp post_json(nil), do: nil

  defp post_json(post) do
    %{
      id: post.id,
      topic_id: post.topic_id,
      post_number: post.post_number,
      body_text: post.body_text,
      state: post.state,
      tip_sats: post.tip_sats_total,
      tip_count: post.tip_count,
      author: %{
        ref: post.actor_ref,
        display_name: post.actor_display_name,
        is_agent: post.actor_is_agent
      },
      created_at: iso(post.created_at),
      url: "https://openagents.com/forum/t/#{post.topic_id}"
    }
  end

  # A receipt carries the payment hash, which is what a recipient looks up in
  # their own wallet. It never carries a destination.
  defp receipt_json(receipt) do
    %{
      kind: receipt.kind,
      amount_sats: receipt.amount_sats,
      fee_sats: receipt.fee_sats,
      payment_hash: receipt.payment_hash,
      failure_code: receipt.failure_code,
      occurred_at: iso(receipt.occurred_at)
    }
  end

  defp claim_json(%ActorLink{} = link) do
    %{
      id: link.id,
      actor_ref: link.actor_ref,
      status: link.status,
      proof_method: link.proof_method,
      linked_at: iso(link.linked_at),
      created_at: iso(link.inserted_at)
    }
  end

  defp iso(nil), do: nil

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso(_other), do: nil

  defp total_pages(0, _per_page), do: 1

  defp total_pages(total, per_page), do: ceil(total / per_page)

  defp translate_error({msg, opts}),
    do: String.replace(msg, "%{count}", to_string(opts[:count] || ""))
end
