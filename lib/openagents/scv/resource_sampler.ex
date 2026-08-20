defmodule OpenAgents.SCV.ResourceSampler do
  @moduledoc """
  Reads bounded process measurements from the worker host.

  The initial local implementation samples the admitted OpenCode process with
  `ps`. Container workers replace this adapter with cgroup measurements while
  preserving the result shape.
  """

  @maximum_ps_output_bytes 1_024

  @spec sample(pos_integer()) :: {:ok, map()} | {:error, atom()}
  def sample(os_pid) when is_integer(os_pid) and os_pid > 0 do
    with executable when is_binary(executable) <- System.find_executable("ps"),
         {output, 0} <-
           System.cmd(executable, ["-o", "rss=", "-o", "%cpu=", "-p", Integer.to_string(os_pid)],
             stderr_to_stdout: true
           ),
         true <- byte_size(output) <= @maximum_ps_output_bytes,
         [rss, cpu] <- String.split(output, ~r/\s+/, trim: true),
         {rss_kib, ""} <- Integer.parse(rss),
         {cpu_percent, ""} <- Float.parse(cpu) do
      {:ok, %{rss_bytes: rss_kib * 1_024, cpu_percent: max(cpu_percent, 0.0)}}
    else
      nil -> {:error, :ps_missing}
      {_output, _status} -> {:error, :sample_failed}
      false -> {:error, :sample_too_large}
      _invalid -> {:error, :sample_invalid}
    end
  end

  def sample(_os_pid), do: {:error, :invalid_pid}
end
