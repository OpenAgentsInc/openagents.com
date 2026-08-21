defmodule OpenAgentsWeb.OGTest do
  use ExUnit.Case, async: true

  alias OpenAgentsWeb.OG

  # ── text safety ────────────────────────────────────────────────────────────
  test "escape XML-escapes the dangerous five and strips control characters" do
    assert OG.escape(~s(<a href="x">&'")) ==
             "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&quot;"

    assert OG.escape("zero\x00one\x1Ftwo") == "zeroonetwo"
    assert OG.escape("plain words 123") == "plain words 123"
    assert OG.escape(nil) == ""
  end

  test "clamp caps length grapheme-safe and marks the cut" do
    assert OG.clamp("short", 10) == "short"

    clamped = OG.clamp(String.duplicate("ab", 50), 20)
    assert String.length(clamped) == 20
    assert String.ends_with?(clamped, "…")
    assert OG.clamp("  padded  ", 20) == "padded"
  end

  test "wrap fits within the budget and ellipsizes only real overflow" do
    lines = OG.wrap("one two three four five", 8, 2)
    assert length(lines) == 2
    assert Enum.all?(lines, &(String.length(&1) <= 9))

    # Fits exactly: no ellipsis invented.
    exact = OG.wrap("aaa bbb ccc", 3, 3)
    assert exact == ["aaa", "bbb", "ccc"]

    overflow = OG.wrap("aaa bbb ccc ddd eee", 7, 2)
    assert length(overflow) == 2
    assert List.last(overflow) =~ "…"

    assert OG.wrap("", 10, 2) == []
    assert OG.wrap(nil, 10, 2) == []

    # A single word longer than the budget survives intact on its own line.
    long = OG.wrap(String.duplicate("x", 40), 10, 1)
    assert String.length(hd(long)) in 10..11
  end

  test "display_path keeps the filename and collapses deep interiors" do
    short = "lib/og.ex"
    assert OG.display_path(short) == short

    deep = "a/b/c/d/e/f/g/really_long_filename_here.ex"
    display = OG.display_path(deep, 24)

    refute String.starts_with?(display, "a/")
    assert display =~ "…/"
    assert String.ends_with?(display, "/really_long_filename_here.ex")
  end

  # ── language inference ─────────────────────────────────────────────────────

  test "language_for_path covers extensions, well-known files, and ignorance" do
    assert OG.language_for_path("lib/openagents/og.ex") == "Elixir"
    assert OG.language_for_path("assets/css/app.css") == "CSS"
    assert OG.language_for_path("Dockerfile") == "Docker"
    assert OG.language_for_path("Makefile") == "Makefile"
    assert OG.language_for_path("src/Main.Swift.swift") == "Swift"
    assert OG.language_for_path("README") == nil
    assert OG.language_for_path("data/blob.unknownext") == nil
  end

  # ── versioning and signing ─────────────────────────────────────────────────

  defp sample_card do
    OG.repo(%OpenAgents.Repositories.Repository{
      name: "openagents.com",
      description: "sample",
      namespace: %{slug: "OpenAgentsInc"}
    })
  end

  test "version is stable for identical inputs and moves when inputs move" do
    card = sample_card()
    assert OG.version(card) == OG.version(sample_card())

    moved = %{card | heading: "different"}
    refute OG.version(card) == OG.version(moved)
  end

  test "request_path is versioned, png-suffixed, and percent-encodes segments" do
    path = OG.request_path(sample_card())

    assert path =~ ~r|^/og/v/[0-9a-f]{12}/repos/OpenAgentsInc/openagents\.com\.png$|

    spaced = %{sample_card() | path_suffix: ["O wner", "a repo"]}
    encoded_path = OG.request_path(spaced)
    assert encoded_path =~ "O%20wner/a%20repo"
    refute encoded_path =~ "+"
  end

  test "signatures verify only their own path" do
    path = OG.request_path(sample_card())
    sig = OG.signature(path)

    assert OG.valid_signature?(path, sig)
    refute OG.valid_signature?(path <> "tampered", sig)
    refute OG.valid_signature?(path, sig <> "x")
    refute OG.valid_signature?(path, nil)
    refute OG.valid_signature?(path, "")
  end

  test "card_url appends a signature over its own path" do
    url = OG.card_url(sample_card())
    assert String.starts_with?(url, OG.site_url())

    [origin_and_path, query] = String.split(url, "?sig=")
    sig = String.replace_prefix(query, "sig=", "")
    path = String.replace_prefix(origin_and_path, OG.site_url(), "")

    assert OG.valid_signature?(path, sig)
  end

  # ── builders ───────────────────────────────────────────────────────────────

  test "the issue builder derives state tone, label chips, and an overflow chip" do
    issue = %{
      number: 12,
      title: "Broken thing",
      user: %{"login" => "ada"},
      state: "closed",
      state_reason: "completed",
      labels: [%{"name" => "bug"}, %{"name" => "ui"}, %{"name" => "css"}, %{"name" => "extra"}],
      comments: 4,
      inserted_at: ~U[2026-08-01 10:00:00Z]
    }

    card = OG.issue("OpenAgentsInc", "openagents.com", issue)

    assert card.heading == "Broken thing"

    assert [
             %{label: "Closed", tone: :done},
             %{label: "bug"},
             %{label: "ui"},
             %{label: "css"},
             %{label: "+1"}
           ] = card.chips

    assert card.avatar == "ada"
    assert "4 comments" in card.stats
    assert card.page_path == "/OpenAgentsInc/openagents.com/issues/12"
  end

  test "an open issue carries the open tone; not_planned closes are muted" do
    open =
      OG.issue("o", "r", %{
        number: 1,
        state: "open",
        labels: [],
        title: "t",
        user: %{"login" => "a"},
        comments: 0,
        inserted_at: ~U[2026-08-01 10:00:00Z]
      })

    assert hd(open.chips).tone == :open

    wontfix =
      OG.issue("o", "r", %{
        number: 2,
        state: "closed",
        state_reason: "not_planned",
        labels: [],
        title: "t",
        user: nil,
        comments: 0,
        inserted_at: ~U[2026-08-01 10:00:00Z]
      })

    assert hd(wontfix.chips) == %{label: "Closed as not planned", tone: :muted}
  end

  test "the blob builder infers language and formats size honestly" do
    card =
      OG.blob("OpenAgentsInc", "openagents.com", "lib/openagents/og.ex", %{
        ref: "main",
        size: 20480,
        lines: 512,
        truncated: false
      })

    assert card.heading == "og.ex"
    assert [%{label: "Elixir"}] = card.chips
    assert "20 KB" in card.stats
    assert "512 lines" in card.stats

    truncated =
      OG.blob("o", "r", "big.bin", %{ref: "main", size: 100, lines: 5, truncated: true})

    assert ">5+ lines" in truncated.stats
    refute "512 lines" in truncated.stats
  end

  test "the commit builder shortens the sha chip and counts files" do
    card =
      OG.commit(
        "OpenAgentsInc",
        "openagents.com",
        %{
          sha: String.duplicate("a", 40),
          subject: "Serve static files",
          author: "ada",
          committed_at: "2026-08-21T12:00:00Z"
        },
        7
      )

    assert [%{label: "aaaaaaa"}] = card.chips
    assert "7 changed files" in card.stats
  end

  # ── templates ──────────────────────────────────────────────────────────────

  test "templates escape hostile content and never embed remote references" do
    hostile =
      OG.repo(%OpenAgents.Repositories.Repository{
        name: "<script>alert(1)</script>",
        description: ~s("&><'\x00) || "evil",
        namespace: %{slug: "O<w>"}
      })
      |> Map.put(:description, ~s("&><'))

    svg = OG.Templates.render(hostile)

    refute svg =~ "<script"
    refute svg =~ "<image"
    refute svg =~ "href="
    assert svg =~ "&lt;script&gt;"
    assert svg =~ ~s(width="1200")
    assert svg =~ ~s(height="630")
  end

  test "template output stays valid XML against control characters" do
    card =
      OG.issue("o", "r", %{
        number: 1,
        title: "bad \x01\x02 title",
        user: %{"login" => "a\x03da"},
        state: "open",
        labels: [],
        comments: 0,
        inserted_at: ~U[2026-08-01 10:00:00Z]
      })

    svg = OG.Templates.render(card)

    # A malformed document exits via xmerl's fatal path; success yields the
    # root element. Byte list: xmerl sniffs the UTF-8 itself.
    {root, _state} = :xmerl_scan.string(:binary.bin_to_list(svg))
    assert elem(root, 0) == :xmlElement
    assert elem(root, 1) == :svg
  end
end

defmodule OpenAgentsWeb.OGLimiterTest do
  use ExUnit.Case, async: false

  alias OpenAgentsWeb.OG.Limiter

  setup do
    previous = Application.get_env(:openagents, :og_max_concurrent)
    Application.put_env(:openagents, :og_max_concurrent, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:openagents, :og_max_concurrent, previous),
        else: Application.delete_env(:openagents, :og_max_concurrent)
    end)

    :ok
  end

  test "acquire bounds concurrency and release frees the slot" do
    assert Limiter.acquire() == :ok
    assert Limiter.acquire() == :busy

    :ok = Limiter.release()
    assert Limiter.acquire() == :ok
    :ok = Limiter.release()

    # Release without acquire must not push the counter below zero.
    :ok = Limiter.release()
    assert Limiter.acquire() == :ok
    :ok = Limiter.release()
  end
end
