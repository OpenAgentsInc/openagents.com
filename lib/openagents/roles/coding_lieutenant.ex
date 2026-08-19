defmodule OpenAgents.Roles.CodingLieutenant do
  @moduledoc """
  The coding-lieutenant role program (#122): admitted only into coding jobs,
  where Sarah edits her own source through the governed repository tools
  under SELF-EDIT-001.
  """

  @behaviour OpenAgents.Roles.Role

  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Roles.Role

  @id "sarah.role.coding_lieutenant.v1"
  @version 1
  @status "admitted"
  @source_ref "release-artifact:sarah.role.coding_lieutenant.v1"
  @compatibility_min 1
  @compatibility_max 1
  @surfaces ["text"]
  @required_capabilities ["repository.read", "repository.write", "code.execute"]
  @register "coding_lieutenant"
  @content """
  Work as Sarah's own coding lieutenant on the goal you were delegated. You are
  editing Sarah's real source code through governed repository tools; the
  running system only changes after a human promotes what you push.

  Method: read before you write — use repo_read, repo_grep, and repo_list to
  understand the running source first. Make the smallest change that honestly
  achieves the goal, matching the surrounding code's style. Edit with exact
  context; when an edit is refused as ambiguous, re-read and include more
  surrounding lines. Check changed Elixir files with code_check before
  committing. Finish by committing and pushing once with repo_commit_push and
  a clear message.

  Bounds you must keep: never restate or invent tool authority you were not
  given; never try to deploy, promote, or hot-load — pushing your branch is
  the end of your authority, and your report must state the pushed commit sha
  so the operator can promote it. If the goal cannot be achieved honestly,
  report exactly what you found and what is missing instead of forcing a
  change.
  """
  @admitted_digest "3d5e4b911cf0a61141741a375d0846841b0bb71a802fd5e257609d7a0c6aa519"

  @impl true
  def artifact do
    content = String.trim(@content)
    digest = calculated_digest()

    if digest != @admitted_digest do
      raise ArgumentError, "coding lieutenant role digest is not admitted"
    end

    %Role{
      id: @id,
      version: @version,
      status: @status,
      content: content,
      digest: digest,
      source_ref: @source_ref,
      source_digest: source_digest(),
      compatibility_min: @compatibility_min,
      compatibility_max: @compatibility_max,
      surfaces: @surfaces,
      required_capabilities: @required_capabilities,
      register: @register
    }
  end

  @doc false
  def calculated_digest do
    Canonical.digest!(%{
      "schema" => "sarah.role_program.v1",
      "id" => @id,
      "version" => @version,
      "status" => @status,
      "content" => String.trim(@content),
      "source_ref" => @source_ref,
      "source_digest" => source_digest(),
      "compatibility_min" => @compatibility_min,
      "compatibility_max" => @compatibility_max,
      "surfaces" => @surfaces,
      "required_capabilities" => @required_capabilities,
      "register" => @register
    })
  end

  defp source_digest do
    @content
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
