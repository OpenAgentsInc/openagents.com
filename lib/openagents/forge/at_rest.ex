defmodule OpenAgents.Forge.AtRest do
  @moduledoc """
  Which columns rest as ciphertext, which rest as plaintext, and which rest as
  something that was never a secret.

  `EXIT-006` published `encrypted_at_rest` as a literal `false` and said so:
  there was no registry of encrypted columns to count, and inventing one so a
  number could appear would be the claim that disclosure exists to prevent.
  This module is not that registry. It is the smaller thing the rule actually
  asks for — a population the database supplies, so a quantified claim about
  columns can fail.

  Three facts are kept apart here because collapsing them is how a store starts
  claiming more than it holds.

  `sealed_columns/0` names the columns that hold reversible secret material and
  the vault that seals each one. It is a floor, not a boast: sealing is under
  keys the operator holds, so it defends against a stolen dump and against
  nothing else, which `VAULT-001` and `VOICE-012` already say in their own
  terms.

  `plaintext_private_columns/0` names columns that hold private, user-authored
  content and rest as plaintext. Its entries are proven plaintext by reading
  the raw column back through SQL, so the list cannot claim a gap that closed,
  and each carries the query that keeps it readable — a column is left in
  plaintext because something reads it in a way a seal would end, never because
  nobody got to it.

  `encrypted_at_rest?/0` is the boolean `EXIT-006` publishes, and it is now
  derived: the private store is encrypted at rest exactly when no private
  column rests as plaintext. The derivation only ever *lowers* the claim. A
  non-empty plaintext list can produce nothing but `false`, so an incomplete
  list understates the store rather than flattering it, which is the direction
  every other gather in `OpenAgents.Forge.Independence` fails in.

  The load-bearing half is `classification/2`. Every column whose name carries
  secret-shaped vocabulary is classified, and the proof derives that population
  from `information_schema` rather than from this file, so a migration that
  adds a plaintext token column fails here on the day it lands instead of on
  the day someone remembers to look. `:plaintext_secret` exists as a
  classification and no column carries it; that assertion is the security
  contract, not the count beside it.

  Issue #193. `docs/2026-08-25-encryption-at-rest.md` records the decision.
  """

  @typedoc "Where a secret-shaped column's contents actually rest."
  @type classification ::
          :sealed
          | :digest
          | :reference
          | :metadata
          | :not_secret
          | :plaintext_secret

  @typedoc "One sealed column and the vault that seals it."
  @type sealed :: %{
          table: String.t(),
          column: String.t(),
          vault: module(),
          holds: String.t()
        }

  @typedoc "One private column that rests as plaintext, and why it still does."
  @type plaintext :: %{
          table: String.t(),
          column: String.t(),
          holds: String.t(),
          reason: String.t()
        }

  # The regular expression the proof hands to `information_schema` to build the
  # population it checks this module against. It lives here so the module and
  # its proof cannot disagree about which columns are in scope.
  @secret_shaped_pattern "(token|secret|credential|password|passphrase|api_key|private_key|mnemonic|seed|nsec|cipher|sealed)"

  @sealed [
    %{
      table: "users",
      column: "github_token_ciphertext",
      vault: OpenAgents.Accounts.TokenVault,
      holds: "delegated GitHub access token"
    },
    %{
      table: "machine_pairings",
      column: "token_ciphertext",
      vault: OpenAgents.Machines.TokenVault,
      holds: "computer token awaiting its pairing claim"
    },
    %{
      table: "voice_recording_chunks",
      column: "data",
      vault: OpenAgents.Voice.RecordingVault,
      holds: "one slice of uploaded call audio"
    },
    %{
      table: "voice_transcript_items",
      column: "content_ciphertext",
      vault: OpenAgents.ContentVault,
      holds: "the voice conversation record VOICE-012 calls authority"
    },
    %{
      table: "voice_sessions",
      column: "compaction_summary_ciphertext",
      vault: OpenAgents.ContentVault,
      holds: "one in-call compaction summary"
    },
    %{
      table: "preference_observations",
      column: "summary_ciphertext",
      vault: OpenAgents.ContentVault,
      holds: "private evidence proposing a behavior preference"
    },
    %{
      table: "project_notes",
      column: "body_ciphertext",
      vault: OpenAgents.ContentVault,
      holds: "project discussion and activity"
    }
  ]

  # Named rather than enumerated, and the reason is the direction of the error.
  # A private column missing from this list leaves `encrypted_at_rest?/0` at
  # `false`, which is where it already is; a column named here that turns out
  # to be sealed turns the proof red. Both failures understate the store.
  @plaintext_private [
    %{
      table: "messages",
      column: "content",
      holds: "conversation messages",
      reason:
        "a generated `search_vector` is computed from this column inside PostgreSQL " <>
          "and indexed with GIN; sealing it ends lexical recall over your own history"
    },
    %{
      table: "issues",
      column: "body",
      holds: "issue bodies",
      reason:
        "`OpenAgents.Issues.search/2` and `OpenAgents.Issues.TaskReferences` match it " <>
          "with `ILIKE`; sealing it ends issue search and cross-references"
    },
    %{
      table: "comments",
      column: "body",
      holds: "issue and pull request comments",
      reason: "`OpenAgents.Issues.TaskReferences` matches it with `ILIKE`"
    },
    %{
      table: "forum_posts",
      column: "body_text",
      holds: "forum replies",
      reason: "`OpenAgents.Forum.search/2` matches it with `ILIKE`"
    },
    %{
      table: "account_chat_runs",
      column: "user_content",
      holds: "what an account typed into the chat console",
      reason:
        "the same words rest verbatim in `account_chat_events.payload`, which the " <>
          "replay path reads structurally; sealing one and not the other moves nothing"
    },
    %{
      table: "account_chat_runs",
      column: "assistant_content",
      holds: "what the model replied in the chat console",
      reason:
        "the same words rest in the `text_delta` events and in the `completion` map " <>
          "beside it, for the same reason"
    }
  ]

  # Every column the catalog reports under `secret_shaped_pattern/0`. The proof
  # derives that population from `information_schema` and fails on anything
  # this map does not answer for, so the map cannot fall behind a migration.
  @classifications %{
    # Reversible secret material, sealed under a vault key.
    {"users", "github_token_ciphertext"} => :sealed,
    {"machine_pairings", "token_ciphertext"} => :sealed,

    # Private content, sealed under the content vault's own key (issue #193).
    {"preference_observations", "summary_ciphertext"} => :sealed,
    {"project_notes", "body_ciphertext"} => :sealed,
    {"voice_sessions", "compaction_summary_ciphertext"} => :sealed,
    {"voice_transcript_items", "content_ciphertext"} => :sealed,

    # One-way SHA-256 of a bearer credential, unique-indexed because it is the
    # lookup key. Nothing reverses these, so nothing seals them.
    {"agent_tokens", "token_digest"} => :digest,
    {"api_tokens", "token_digest"} => :digest,
    {"deployment_workflow_grants", "token_digest"} => :digest,
    {"forge_assignment_credentials", "token_digest"} => :digest,
    {"inference_grants", "token_digest"} => :digest,
    {"machine_pairings", "poll_secret_digest"} => :digest,
    {"machines", "token_digest"} => :digest,

    # A pointer to secret material held somewhere else, an algorithm name, or a
    # public half. No secret rests in the column.
    {"deployment_environments", "secret_references"} => :reference,
    {"portable_export_receipts", "cipher_id"} => :reference,
    {"reputation_signing_keys", "public_key"} => :reference,
    {"scv_driver_accounts", "credential_kind"} => :reference,
    {"scv_driver_accounts", "credential_version"} => :reference,
    {"scv_driver_accounts", "secret_ref"} => :reference,

    # Lifecycle sidecars for a secret that rests elsewhere: which key sealed
    # it, when it was issued, whether it is sealed at all.
    {"device_authorizations", "api_token_id"} => :metadata,
    {"forge_assignments", "credential_delivery_reason"} => :metadata,
    {"forge_assignments", "credential_delivery_status"} => :metadata,
    {"machines", "scoped_forge_credentials_enabled"} => :metadata,
    {"machines", "token_expires_at"} => :metadata,
    {"users", "github_token_connected_at"} => :metadata,
    {"users", "github_token_key_id"} => :metadata,
    {"users", "github_token_rotated_at"} => :metadata,
    {"users", "github_token_scopes"} => :metadata,
    {"voice_recordings", "sealed"} => :metadata,

    # The vocabulary matched and the meaning did not: deduplication keys,
    # identity keys, and token counters carry no secret.
    {"box_runs", "idempotency_key"} => :not_secret,
    {"compensation_events", "invocation_key"} => :not_secret,
    {"compensation_outcome_decisions", "invocation_key"} => :not_secret,
    {"deployment_requests", "idempotency_key"} => :not_secret,
    {"effects", "idempotency_key"} => :not_secret,
    {"forum_posts", "idempotency_key"} => :not_secret,
    {"forum_tip_intents", "idempotency_key"} => :not_secret,
    {"forum_topics", "idempotency_key"} => :not_secret,
    {"graph_artifacts", "conflict_key"} => :not_secret,
    {"graph_artifacts", "identity_key"} => :not_secret,
    {"graph_artifacts", "version_key"} => :not_secret,
    {"gym_runs", "input_tokens"} => :not_secret,
    {"gym_runs", "output_tokens"} => :not_secret,
    {"inference_grants", "max_total_tokens"} => :not_secret,
    {"namespace_aliases", "slug_key"} => :not_secret,
    {"namespaces", "slug_key"} => :not_secret,
    {"notifications", "dedupe_key"} => :not_secret,
    {"preferences", "effect_key"} => :not_secret,
    {"pull_request_stack_idempotency_requests", "idempotency_key"} => :not_secret,
    {"repositories", "name_key"} => :not_secret,
    {"repositories", "owner_key"} => :not_secret,
    {"repositories", "storage_key"} => :not_secret,
    {"repository_idempotency_requests", "idempotency_key"} => :not_secret,
    {"repository_publications", "idempotency_key"} => :not_secret,
    {"settlement_payment_intents", "idempotency_key"} => :not_secret,
    {"stack_operations", "idempotency_key"} => :not_secret,
    {"turn_tool_steps", "billable_attribution_key"} => :not_secret,
    {"turn_tool_steps", "invocation_key"} => :not_secret
  }

  @doc """
  Whether the private store is encrypted at rest.

  True exactly when no private column rests as plaintext, which is what
  `EXIT-006` publishes and `OpenAgents.Forge.Independence` derives
  `operator_reads_source` from.
  """
  @spec encrypted_at_rest?() :: boolean()
  def encrypted_at_rest?, do: Enum.empty?(plaintext_private_columns())

  @doc "Columns that hold reversible secret material, and the vault sealing each."
  @spec sealed_columns() :: [sealed()]
  def sealed_columns, do: @sealed

  @doc "Private, user-authored columns that rest as plaintext."
  @spec plaintext_private_columns() :: [plaintext()]
  def plaintext_private_columns, do: @plaintext_private

  @doc """
  Where a secret-shaped column's contents rest, or `nil` when unclassified.

  An unclassified column is a proof failure rather than a silent `:not_secret`:
  the point is that a new one cannot pass unnoticed.
  """
  @spec classification(String.t(), String.t()) :: classification() | nil
  def classification(table, column) when is_binary(table) and is_binary(column),
    do: Map.get(@classifications, {table, column})

  @doc "Every classified column, as `{{table, column}, classification}` pairs."
  @spec classifications() :: %{{String.t(), String.t()} => classification()}
  def classifications, do: @classifications

  @doc """
  The PostgreSQL regular expression that selects secret-shaped column names.

  The proof hands this to `information_schema` so the population it checks is
  the database's answer rather than this module's.
  """
  @spec secret_shaped_pattern() :: String.t()
  def secret_shaped_pattern, do: @secret_shaped_pattern
end
