#!/usr/bin/env elixir

case System.argv() do
  [path] ->
    case OpenAgents.LogSafety.scan_file(path) do
      :ok ->
        IO.puts("private_log_scan=clean")

      {:error, findings} when is_list(findings) ->
        Enum.each(findings, fn finding ->
          IO.puts(:stderr, "private_log_scan=#{finding.kind} line=#{finding.line}")
        end)

        System.halt(1)

      {:error, :unreadable} ->
        IO.puts(:stderr, "private_log_scan=unreadable")
        System.halt(1)
    end

  _arguments ->
    IO.puts(:stderr, "usage: mix run --no-start ops/ci/private-log-scan.exs LOG_FILE")
    System.halt(64)
end
