defmodule OpenAgents.Threads.WekaExport do
  @moduledoc """
  Exports a ledger-visible thread transcript into a WEKA-trace v1 document.

  The output is a content-anonymized, chain-hashed trajectory that preserves
  event metadata (role, type, timestamps, block counts) but replaces every
  raw text payload with deterministic SHA-256 block hashes. Export is
  consent-gated by the thread's visibility tier (THREAD-002).
  """

  import Ecto.Query

  alias OpenAgents.Repo
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.Thread

  @weka_format "weka-trace-v1"
  @chunk_size 64
  @hash_display 16

  @doc """
  Exports a thread to a WEKA-trace v1 document.

  Accepts a `Thread` struct or a thread id (UUID string). The optional `salt`
  is caller-supplied and defaults to `""`. Returns `{:ok, document}` for a
  ledger-visible thread, or `{:error, :consent_required}` /
  `{:error, :thread_not_found}` otherwise.
  """
  @spec export(Thread.t() | String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def export(thread_or_id, salt \\ "")

  def export(%Thread{} = thread, salt) when is_binary(salt) do
    do_export(thread, salt)
  end

  def export(thread_id, salt) when is_binary(thread_id) and is_binary(salt) do
    case Ecto.UUID.cast(thread_id) do
      {:ok, id} ->
        case Repo.get(Thread, id) do
          %Thread{} = thread -> do_export(thread, salt)
          nil -> {:error, :thread_not_found}
        end

      :error ->
        {:error, :thread_not_found}
    end
  end

  defp do_export(%Thread{} = thread, salt) do
    if Thread.wide?(thread) do
      events = load_events(thread)
      session_salt = derive_session_salt(thread, salt)
      {event_docs, total_blocks} = build_trace(events, session_salt)

      document = %{
        "format" => @weka_format,
        "thread_id" => thread.id,
        "generation" => thread.generation,
        "visibility" => thread.visibility,
        "started_at" => format_dt(thread.started_at),
        "completed_at" => format_dt(thread.completed_at),
        "event_count" => length(events),
        "total_blocks" => total_blocks,
        "events" => event_docs
      }

      {:ok, document}
    else
      {:error, :consent_required}
    end
  end

  defp load_events(%Thread{id: thread_id}) do
    from(e in Event,
      where: e.thread_id == ^thread_id,
      order_by: [asc: e.id]
    )
    |> Repo.all()
  end

  defp derive_session_salt(%Thread{id: thread_id}, salt) do
    :crypto.hash(:sha256, "#{thread_id}:#{salt}")
    |> Base.encode16(case: :lower)
  end

  defp build_trace(events, session_salt) do
    events
    |> Enum.reduce({[], 0, session_salt}, fn event, {docs, total, prev_hash} ->
      text = extract_text(event.payload)
      tokens = String.split(text, ~r/\s+/, trim: true)
      chunks = Enum.chunk_every(tokens, @chunk_size)
      {blocks, next_hash} = hash_chunks(chunks, session_salt, prev_hash)

      event_doc = %{
        "id" => event.id,
        "event_type" => event.event_type,
        "emitted_at" => format_dt(event.emitted_at),
        "role" => extract_role(event),
        "block_count" => length(blocks),
        "blocks" => blocks
      }

      {[event_doc | docs], total + length(blocks), next_hash}
    end)
    |> then(fn {docs, total, _hash} -> {Enum.reverse(docs), total} end)
  end

  defp hash_chunks(chunks, session_salt, initial_hash) do
    {blocks, final_hash} =
      Enum.reduce(chunks, {[], initial_hash}, fn chunk, {blocks, prev} ->
        chunk_text = Enum.join(chunk, " ")

        hash =
          :crypto.hash(:sha256, session_salt <> prev <> chunk_text)
          |> Base.encode16(case: :lower)
          |> String.slice(0, @hash_display)

        {[hash | blocks], hash}
      end)

    {Enum.reverse(blocks), final_hash}
  end

  defp extract_text(payload) when is_map(payload) do
    case payload["content"] || payload["text"] || payload["message"] || payload["output"] do
      value when is_binary(value) -> value
      nil -> Jason.encode!(payload)
      value -> Jason.encode!(value)
    end
  end

  defp extract_text(payload) when is_binary(payload), do: payload
  defp extract_text(_payload), do: ""

  defp extract_role(%Event{event_type: type, payload: payload}) do
    case payload do
      %{"role" => role} when is_binary(role) -> role
      _ -> role_from_type(type)
    end
  end

  defp role_from_type("turn." <> rest), do: rest
  defp role_from_type("tool." <> _), do: "tool"
  defp role_from_type("thread." <> _), do: "system"
  defp role_from_type(_), do: "unknown"

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(nil), do: nil
end
