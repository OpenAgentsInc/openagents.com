defmodule OpenAgentsWeb.OgImageController do
  @moduledoc """
  Serves server-generated Open Graph card PNGs.

  Contract, from `docs/2026-08-21-open-graph-cards.md`:

    * Every request path is HMAC-signed (`?sig=`); an invalid or missing
      signature is the same 404 as everything else this endpoint refuses.
    * Repositories resolve through the public visibility predicate only. A
      private repository, a missing repository, and a bad signature are
      indistinguishable.
    * The version segment is advisory: it exists so a page's emitted URL is
      content-addressed and caches immutably. The controller always renders
      current data for any well-formed request, so stale shared links heal
      instead of pinning old facts.
    * When rasterization is unavailable, busy, or fails, the committed
      fallback card ships under identical headers — previews degrade,
      nothing errors.
  """

  use OpenAgentsWeb, :controller

  require Logger

  alias OpenAgents.Forge
  alias OpenAgents.Forge.Browse
  alias OpenAgents.Issues
  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories
  alias OpenAgents.Stacks
  alias OpenAgentsWeb.{DocsCatalog, OG, RepositoryAccess}

  @cache_control "public, max-age=21600, immutable"
  @not_found_cache_control "public, max-age=60"

  # Last-resort bytes if even the committed fallback asset cannot be read: a
  # valid transparent 1x1 PNG keeps responses well-formed.
  @transparent_png Base.decode64!(
                     "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
                   )

  ## Actions -------------------------------------------------------------------

  def static(conn, _params) do
    send_png(conn)
  end

  def repo(conn, params) do
    authorize_and_run(conn, params, fn owner, name ->
      with {:ok, repository} <- public_repository(owner, name) do
        OG.repo_card_for(repository)
      else
        _error -> :error
      end
    end)
  end

  def issue(conn, params) do
    authorize_and_run(conn, params, fn owner, name ->
      with {number, ""} <- Integer.parse(strip_png(params["number"])),
           %Issues.Issue{} = issue <-
             safe(fn -> Issues.get_issue_by_path!(owner, name, number) end) do
        OG.issue(owner, name, issue)
      else
        _error -> :error
      end
    end)
  end

  def pull(conn, params) do
    authorize_and_run(conn, params, fn owner, name ->
      with {number, ""} <- Integer.parse(strip_png(params["number"])),
           {:ok, repository} <- public_repository(owner, name),
           %PullRequests.PullRequest{} = pull_request <-
             safe(fn -> PullRequests.get_by_number!(repository, number) end) do
        {position, size} = stack_placement(repository, pull_request)

        OG.pull_request(owner, name, pull_request,
          stack_position: position,
          stack_size: size
        )
      else
        _error -> :error
      end
    end)
  end

  # Documentation is public by construction: the catalog is the compile-time
  # allowlist, so a slug it cannot render is the same 404 as a bad signature.
  def docs(conn, params) do
    authorized(conn, fn ->
      case DocsCatalog.render(strip_png(params["slug"]) || "") do
        {:ok, page} -> OG.docs(page)
        :error -> :error
      end
    end)
  end

  def commit(conn, params) do
    authorize_and_run(conn, params, fn owner, name ->
      sha = strip_png(params["sha"])

      with {:ok, repository} <- public_repository(owner, name),
           true <- Forge.enabled?(),
           true <- Browse.valid_ref?(sha),
           {:ok, commit} <- safe(fn -> Browse.commit(repository, sha) end) do
        files =
          case safe(fn -> Browse.changed_files(repository, commit.sha) end) do
            {:ok, list} when is_list(list) -> list
            _other -> nil
          end

        OG.commit(owner, name, commit, files && length(files))
      else
        _error -> :error
      end
    end)
  end

  # The blob card must never show what the anonymous file page would not:
  # the same disclosure gate as `OpenAgentsWeb.CodeBlobLive` runs here, with
  # no user (crawlers carry no session).
  def blob(conn, params) do
    authorize_and_run(conn, params, fn owner, name ->
      ref = strip_png(params["ref"])
      path = joined_path(params["path"])

      with {:ok, repository} <- public_repository(owner, name),
           true <- Forge.enabled?() and repository.lifecycle_state == "ready",
           true <- Browse.valid_ref?(ref) and Browse.valid_path?(path),
           {:ok, sha} <- safe(fn -> Browse.resolve_commit(repository, ref) end),
           head <- resolved_head(repository),
           true <- RepositoryAccess.allows_file?(repository, nil, path, sha, head),
           {:ok, blob_info} <- safe(fn -> Browse.blob(repository, sha, path) end) do
        OG.blob(owner, name, path, %{
          ref: ref,
          size: blob_info.size,
          lines: blob_lines(blob_info),
          truncated: blob_info.truncated
        })
      else
        _refused -> :error
      end
    end)
  end

  ## Pipeline ------------------------------------------------------------------

  # One response for every refusal — bad signature, unknown repository,
  # private repository, missing resource — so none of them can be told apart.
  defp authorize_and_run(conn, params, build) do
    authorized(conn, fn ->
      build.(strip_png(params["owner"]), strip_png(params["repo"]))
    end)
  end

  defp authorized(conn, build) do
    if OG.valid_signature?(conn.request_path, conn.query_params["sig"]) do
      case build.() do
        %OG{} = card -> respond_with_card(conn, card)
        _refused -> not_found(conn)
      end
    else
      not_found(conn)
    end
  end

  defp respond_with_card(conn, card) do
    svg = OG.Templates.render(card)

    case OG.Rasterizer.rasterize(svg) do
      {:ok, png} ->
        send_png(conn, png)

      {:error, reason} ->
        # Exit tuples can carry payloads; log the safe classification only.
        safe_reason =
          case reason do
            {:exit, _payload} -> :exit
            other -> other
          end

        Logger.warning("og_card_fallback kind=#{card.kind} reason=#{safe_reason}")

        send_png(conn, fallback_png())
    end
  end

  defp send_png(conn, bytes \\ nil) do
    conn
    |> put_resp_header("content-type", "image/png")
    |> put_resp_header("cache-control", @cache_control)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, bytes || default_card_bytes())
  end

  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", @not_found_cache_control)
    |> send_resp(404, "")
  end

  ## Helpers -------------------------------------------------------------------

  defp stack_placement(repository, pull_request) do
    case safe(fn -> Stacks.review_context(repository, pull_request) end) do
      {:ok, context} -> {context.position, context.size}
      _other -> merged_stack_placement(pull_request)
    end
  end

  defp merged_stack_placement(pull_request) do
    case safe(fn -> Stacks.merged_context(pull_request) end) do
      {:ok, context} -> {context.position, context.size}
      _other -> {nil, nil}
    end
  end

  defp public_repository(owner, name) do
    case safe(fn -> Repositories.get_public_by_path!(owner, name) end) do
      %Repositories.Repository{} = repository -> {:ok, repository}
      _other -> :error
    end
  end

  # `Browse.head/1` reports emptiness as an error tuple; the disclosure gate
  # only wants a sha or nil, exactly as the file page derives it.
  defp resolved_head(repository) do
    case safe(fn -> Browse.head(repository) end) do
      {:ok, sha} -> sha
      _other -> nil
    end
  end

  # ".png" rides at the end of the last path segment; a resource genuinely
  # named "*.png" arrives doubled and survives one strip intact.
  defp strip_png(nil), do: nil

  defp strip_png(value) when is_binary(value),
    do: String.replace_suffix(value, ".png", "")

  defp joined_path(segments) when is_list(segments) do
    segments
    |> Enum.join("/")
    |> String.replace_suffix(".png", "")
  end

  defp joined_path(_other), do: ""

  defp blob_lines(%{binary: true}), do: nil

  defp blob_lines(%{content: content}) when is_binary(content),
    do: content |> String.split("\n") |> length()

  defp blob_lines(_blob_info), do: nil

  defp safe(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # The committed brand card doubles as the rasterization fallback, cached in
  # process-global storage after its first read.
  defp fallback_png do
    key = {__MODULE__, :fallback_png}

    case :persistent_term.get(key, nil) do
      nil ->
        path = Application.app_dir(:openagents, "priv/static/images/og-card-default.png")

        case File.read(path) do
          {:ok, bytes} ->
            :persistent_term.put(key, bytes)
            bytes

          _unreadable ->
            @transparent_png
        end

      bytes ->
        bytes
    end
  end

  defp default_card_bytes do
    # The static route serves exactly the committed asset; the fallback bytes
    # are the same file, so both paths share one read.
    fallback_png()
  end
end
