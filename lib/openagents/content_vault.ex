defmodule OpenAgents.ContentVault do
  @moduledoc """
  AES-256-GCM sealing for private text that nobody searches.

  The three vaults that came before this one each seal a credential or a
  recording. This one seals *content*: sentences a person wrote or spoke that
  rest in PostgreSQL and that no query reads except whole. Issue #193 asked
  which columns those are, and
  `docs/2026-08-25-encryption-at-rest.md` names every one that is sealed here
  and every one that is not, with the query that keeps it plaintext.

  ## Its own key, and one key for this whole domain

  `VAULT-001` binds the property that rotating one vault's key never unreads
  another vault's records. This vault reads `:content_encryption_key` and
  nothing else — no fallback to the GitHub keyring, no bridge to the recording
  key. Issue #253 is what that bridge costs.

  It is one vault over several columns rather than one vault per column, and
  that is a decision rather than an omission. The separation that carries
  weight is credential from content: a stolen GitHub token key must not open a
  conversation, and a conversation key must not open a token. Splitting the
  content columns from each other would buy a finer rotation blast radius at
  the price of one production secret per column, and every column here is
  readable by the same operator through the same application anyway. Rotating
  this key strands every column it seals, together, which is the cost recorded
  in `VAULT-001`'s rotation posture.

  ## What the seal is bound to

  Every seal carries additional authenticated data naming the column it belongs
  to and the row's own identity, so ciphertext cannot be lifted from one row
  into another, or from one column into another, and still open. `scope/0`
  values are the table and column; `binding` is whatever identifies the row
  immutably — usually its natural key.

  ## What it does not do

  It seals under a key the operator holds, so it defends against a stolen dump,
  a stolen backup, and a stolen disk. It does not defend against the operator,
  and `EXIT-006` keeps `encrypted_at_rest` from claiming otherwise: the
  disclosure stays `false` while any private column rests as plaintext, and
  `operator_reads_source` stays `true` regardless.
  """

  @version 1
  @nonce_bytes 12
  @tag_bytes 16
  # Large enough for the longest column this vault seals: a 20,000-character
  # project note, whose Ecto bound counts graphemes rather than bytes.
  @maximum_content_bytes 131_072
  @aad_prefix "openagents.content.v1:"

  @typedoc "The table and column a seal belongs to."
  @type scope :: String.t()

  @typedoc "The row identity a seal is bound to, in a fixed order."
  @type binding :: [String.t() | integer()]

  @doc "Whether this vault holds its own key."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _key}, key())

  @doc """
  Seals `content` for one column and one row.

  `scope` names the column, `binding` names the row. Both travel as
  authenticated data rather than as ciphertext, so opening a value under the
  wrong column or the wrong row fails instead of succeeding quietly.
  """
  @spec seal(String.t(), scope(), binding()) :: {:ok, binary()} | {:error, atom()}
  def seal(content, scope, binding)
      when is_binary(content) and byte_size(content) in 1..@maximum_content_bytes do
    with {:ok, aad} <- aad(scope, binding),
         {:ok, key} <- key() do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, content, aad, true)

      {:ok, <<@version, nonce::binary, tag::binary, ciphertext::binary>>}
    end
  end

  def seal(_content, _scope, _binding), do: {:error, :invalid_content}

  @doc "Opens a sealed value, refusing one bound to another column or row."
  @spec open(binary(), scope(), binding()) :: {:ok, String.t()} | {:error, atom()}
  def open(
        <<@version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>,
        scope,
        binding
      ) do
    with {:ok, aad} <- aad(scope, binding),
         {:ok, key} <- key() do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
        content when is_binary(content) -> {:ok, content}
        :error -> {:error, :content_unsealable}
      end
    end
  end

  def open(_sealed, _scope, _binding), do: {:error, :content_unsealable}

  @doc """
  The plaintext, or `nil` when there is no seal to open.

  Readers render a missing sentence rather than crashing a page: a rotated key
  strands prior content, which `VAULT-001` records as this vault's rotation
  cost, and a crash there would take a whole timeline or project down with it.
  """
  @spec text(binary() | nil, scope(), binding()) :: String.t() | nil
  def text(nil, _scope, _binding), do: nil

  def text(sealed, scope, binding) when is_binary(sealed) do
    case open(sealed, scope, binding) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end

  @doc "The largest value this vault seals."
  @spec maximum_content_bytes() :: pos_integer()
  def maximum_content_bytes, do: @maximum_content_bytes

  @doc "How many bytes sealing adds to a value, for a column's own bound."
  @spec overhead_bytes() :: pos_integer()
  def overhead_bytes, do: 1 + @nonce_bytes + @tag_bytes

  defp aad(scope, binding) when is_binary(scope) and is_list(binding) do
    if binding == [] or Enum.any?(binding, &is_nil/1) do
      {:error, :invalid_content_binding}
    else
      {:ok, @aad_prefix <> scope <> ":" <> Enum.map_join(binding, ":", &to_string/1)}
    end
  end

  defp aad(_scope, _binding), do: {:error, :invalid_content_binding}

  defp key do
    with encoded when is_binary(encoded) <-
           Application.get_env(:openagents, :content_encryption_key),
         {:ok, key} when byte_size(key) == 32 <- Base.decode64(encoded) do
      {:ok, key}
    else
      _missing -> {:error, :content_vault_not_configured}
    end
  end
end
