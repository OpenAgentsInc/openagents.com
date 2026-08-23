defmodule OpenAgents.DocsCheck do
  @moduledoc false

  @root File.cwd!()
  @markdown_files ["README.md", "INVARIANTS.md"] ++ Path.wildcard("docs/**/*.md")

  # These records must preserve the terms they measure or prohibit. Current
  # product narratives and closed migration records remain subject to the scan.
  @lexical_exceptions MapSet.new([
                        "docs/2026-08-20-integration-hardening-and-staging-readiness-recommendations.md",
                        "docs/2026-08-20-test-coverage-audit.md",
                        "docs/episode-triage.md",
                        "docs/decisions/0005-use-basecoat-and-one-component-system.md"
                      ])

  @banned_terms [
    {~r/\bDaisyUI\b/i, "retired component library"},
    {~r/\b(?:pro|api)\.openagents\.com\b/i, "retired private-service domain"},
    {~r/OpenAgentsWeb\.SarahUI/, "retired generic component module"},
    {~r/OpenAgents\.Sarah\.Supervisor/, "retired generic supervisor"},
    {~r/style-sarah\.css|style-openagents\.css/, "retired style-pack path"},
    {~r/priv\/openagents\//, "nonexistent artifact root"}
  ]

  @developer_paths [
    {~r{~/(?:work|code)(?:/|\b)}, "home-relative developer path"},
    {~r{/Users/[A-Za-z0-9._-]+/(?:work|code)(?:/|\b)}, "macOS developer path"},
    {~r{/home/[A-Za-z0-9._-]+/(?:work|code)(?:/|\b)}, "Linux developer path"}
  ]

  @theme_contract_files ["AGENTS.md", "INVARIANTS.md", "docs/component-library.md"]
  @retired_theme_claims [
    {~r/\bdark-only\b/i, "retired dark-only theme claim"},
    {~r/\bsingle dark theme\b/i, "retired single-theme claim"},
    {~r/\bno theme selector enters the bundle\b/i, "retired selector-free theme claim"}
  ]

  def run do
    errors =
      []
      |> check_markdown_links()
      |> check_current_language()
      |> check_theme_contract()
      |> check_invariants()

    case Enum.reverse(errors) do
      [] ->
        IO.puts("Documentation check passed (#{length(@markdown_files)} Markdown files).")

      failures ->
        Enum.each(failures, &IO.puts(:stderr, "documentation check: #{&1}"))
        System.halt(1)
    end
  end

  defp check_markdown_links(errors) do
    Enum.reduce(@markdown_files, errors, fn file, acc ->
      content = File.read!(file)

      Regex.scan(~r/\[[^\]]*\]\(([^)]+)\)/, content, capture: :all_but_first)
      |> Enum.reduce(acc, fn [raw_target], link_errors ->
        target =
          raw_target
          |> String.trim()
          |> String.trim_leading("<")
          |> String.trim_trailing(">")
          |> String.split(~r/\s+"/, parts: 2)
          |> hd()
          |> String.split("#", parts: 2)
          |> hd()
          |> String.split("?", parts: 2)
          |> hd()

        if external_or_route?(target) do
          link_errors
        else
          resolved = Path.expand(target, Path.dirname(Path.join(@root, file)))

          if File.exists?(resolved) do
            link_errors
          else
            ["#{file} links to missing local target #{inspect(raw_target)}" | link_errors]
          end
        end
      end)
    end)
  end

  defp external_or_route?(target) do
    target == "" or String.starts_with?(target, ["#", "/", "http://", "https://", "mailto:"])
  end

  defp check_current_language(errors) do
    @markdown_files
    |> Enum.reject(&MapSet.member?(@lexical_exceptions, &1))
    |> Enum.reduce(errors, fn file, acc ->
      content = File.read!(file)

      acc
      |> scan_terms(file, content, @banned_terms)
      |> scan_terms(file, content, @developer_paths)
    end)
  end

  defp scan_terms(errors, file, content, patterns) do
    Enum.reduce(patterns, errors, fn {pattern, label}, acc ->
      case Regex.run(pattern, content, return: :index) do
        nil ->
          acc

        [{offset, _length} | _captures] ->
          ["#{file}:#{line_at(content, offset)} contains #{label}" | acc]
      end
    end)
  end

  defp check_theme_contract(errors) do
    Enum.reduce(@theme_contract_files, errors, fn file, acc ->
      scan_terms(acc, file, File.read!(file), @retired_theme_claims)
    end)
  end

  defp check_invariants(errors) do
    content = File.read!("INVARIANTS.md")
    sections = invariant_sections(content)
    ids = Enum.map(sections, & &1.id)

    errors
    |> check_duplicate_ids(ids)
    |> check_statuses(sections)
    |> check_proof_index(content, sections)
    |> check_invariant_paths(content)
    |> check_module_references(content)
  end

  defp invariant_sections(content) do
    Regex.split(~r/(?=^### [A-Z][A-Z0-9-]+-\d{3} — )/m, content)
    |> Enum.flat_map(fn section ->
      case Regex.run(~r/^### ([A-Z][A-Z0-9-]+-\d{3}) — /, section, capture: :all_but_first) do
        [id] -> [%{id: id, body: section}]
        nil -> []
      end
    end)
  end

  defp check_duplicate_ids(errors, ids) do
    ids
    |> Enum.frequencies()
    |> Enum.reduce(errors, fn
      {id, count}, acc when count > 1 -> ["INVARIANTS.md contains duplicate ID #{id}" | acc]
      {_id, _count}, acc -> acc
    end)
  end

  defp check_statuses(errors, sections) do
    Enum.reduce(sections, errors, fn section, acc ->
      statuses =
        Regex.scan(~r/^Status: (Current|Proposed)$/m, section.body, capture: :all_but_first)

      case statuses do
        [[_status]] -> acc
        _other -> ["#{section.id} must declare exactly one Current or Proposed status" | acc]
      end
    end)
  end

  defp check_proof_index(errors, content, sections) do
    rows =
      Regex.scan(
        ~r/^\| ([A-Z][A-Z0-9-]+-\d{3}) \| (.+) \|$/m,
        content,
        capture: :all_but_first
      )

    proof_rows = Map.new(rows, fn [id, proof] -> {id, proof} end)
    section_ids = MapSet.new(sections, & &1.id)
    proof_ids = MapSet.new(Map.keys(proof_rows))

    errors =
      Enum.reduce(MapSet.difference(section_ids, proof_ids), errors, fn id, acc ->
        ["proof index is missing #{id}" | acc]
      end)

    errors =
      Enum.reduce(MapSet.difference(proof_ids, section_ids), errors, fn id, acc ->
        ["proof index names unknown invariant #{id}" | acc]
      end)

    Enum.reduce(sections, errors, fn section, acc ->
      current? = Regex.match?(~r/^Status: Current$/m, section.body)
      proof = Map.get(proof_rows, section.id, "")

      if current? and not Regex.match?(~r/`(?:test|assets\/test|ops)\/[^`]+`/, proof) do
        ["current invariant #{section.id} has no executable proof file" | acc]
      else
        acc
      end
    end)
  end

  defp check_invariant_paths(errors, content) do
    Regex.scan(~r/`([^`]+)`/, content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&local_evidence_path?/1)
    |> Enum.uniq()
    |> Enum.reduce(errors, fn path, acc ->
      normalized = String.trim_trailing(path, "/")

      if File.exists?(normalized) do
        acc
      else
        ["INVARIANTS.md names missing evidence path #{path}" | acc]
      end
    end)
  end

  defp local_evidence_path?(path) do
    String.starts_with?(path, ["assets/", "config/", "docs/", "ops/", "priv/", "test/"]) or
      path in [".dockerignore", ".gitignore", "AGENTS.md", "INVARIANTS.md"]
  end

  defp check_module_references(errors, content) do
    module_files = Path.wildcard("{lib,test}/**/*.{ex,exs}")

    declared =
      module_files
      |> Enum.flat_map(fn file ->
        Regex.scan(
          ~r/defmodule\s+(OpenAgents(?:Web)?(?:\.[A-Z][A-Za-z0-9_]*)*)\s+do/,
          File.read!(file), capture: :all_but_first)
        |> List.flatten()
      end)
      |> MapSet.new()

    Regex.scan(~r/`([^`]+)`/, content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&String.contains?(&1, "*"))
    |> Enum.flat_map(fn token ->
      case Regex.run(
             ~r/^(OpenAgents(?:Web)?(?:\.[A-Z][A-Za-z0-9_]*)+)/,
             token,
             capture: :all_but_first
           ) do
        [module] -> [module]
        nil -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.reduce(errors, fn module, acc ->
      if MapSet.member?(declared, module) do
        acc
      else
        ["INVARIANTS.md names missing module #{module}" | acc]
      end
    end)
  end

  defp line_at(content, offset) do
    content
    |> binary_part(0, offset)
    |> String.split("\n")
    |> length()
  end
end

OpenAgents.DocsCheck.run()
