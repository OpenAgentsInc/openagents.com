defmodule OpenAgentsWeb.Plugs.SidebarSections do
  @moduledoc """
  Carries which sidebar sections the reader has collapsed into the session, so
  the server can render them collapsed on the first paint.

  The reader's choice used to live only in the browser, applied by a hook after
  the document arrived. That is correct but late: several sidebar destinations
  cross live sessions, so moving between them is a full page load, and the
  server -- knowing nothing -- sent every section open. The reader watched a
  section they had collapsed appear and then collapse again on every
  navigation.

  A preference that has to affect the first paint has to travel with the
  request, which for a browser means a cookie. The hook writes one; this reads
  it into the session, where a LiveView mount can see it.

  The value is a reader's own UI state, so it is treated as untrusted input and
  bounded on the way in: unparseable JSON, a non-object, oversized content, or
  keys that are not section ids are dropped rather than passed inward.

  ## Scoping

  There is one namespace, shared by every surface, keyed by the section id that
  `OpenAgentsWeb.Layouts.sidebar_section/1` derives from the section title. A
  section named the same thing on two surfaces is therefore one preference:
  collapse it on `/docs` and it is collapsed on `/components` too. That is the
  rule on purpose -- a reader who hides a group of links is talking about the
  group, not about the page they happened to be on -- and
  `test/openagents_web/sidebar_state_test.exs` pins it. A surface that needs a
  section of its own passes an explicit `id` rather than relying on its title
  being unique.
  """

  @behaviour Plug

  @cookie "sidebar_sections"
  @session_key "sidebar_sections"

  # A section id per collapsible group, and no group has many. Well past what
  # the application renders, and far short of anything worth storing.
  @maximum_sections 64
  @maximum_bytes 2_048
  @id_pattern ~r/^sidebar-section-[a-z0-9-]{1,64}$/

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    conn = Plug.Conn.fetch_cookies(conn)
    sections = parse(conn.cookies[@cookie])

    # Written only on change. The session cookie is re-signed and re-sent on
    # every write, and this value changes when a reader clicks a caret, not
    # when they load a page.
    if sections == Plug.Conn.get_session(conn, @session_key) do
      conn
    else
      Plug.Conn.put_session(conn, @session_key, sections)
    end
  end

  @doc "The sections map held in a LiveView's session, or an empty map."
  @spec from_session(map()) :: %{optional(String.t()) => boolean()}
  def from_session(session) when is_map(session) do
    case session[@session_key] do
      state when is_map(state) -> state
      _absent_or_wrong_shape -> %{}
    end
  end

  def from_session(_session), do: %{}

  defp parse(nil), do: %{}

  defp parse(value) when byte_size(value) > @maximum_bytes, do: %{}

  defp parse(value) do
    with {:ok, decoded} <- URI.decode(value) |> Jason.decode(),
         true <- is_map(decoded) do
      decoded
      |> Enum.filter(&admissible?/1)
      |> Enum.take(@maximum_sections)
      |> Map.new()
    else
      _unusable -> %{}
    end
  rescue
    # `URI.decode/1` raises on a malformed percent sequence, which a hand-edited
    # cookie can carry.
    ArgumentError -> %{}
  end

  defp admissible?({key, value}) when is_binary(key) and is_boolean(value),
    do: Regex.match?(@id_pattern, key)

  defp admissible?(_pair), do: false
end
