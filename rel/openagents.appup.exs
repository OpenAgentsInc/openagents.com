# Supported hot-upgrade instructions for the :openagents app.
#
# The instruction set applies to any concrete from/to version pair: the
# advanced update drives `ReleaseState.code_change/3`, which handles upgrade,
# downgrade, and same-schema transitions, and the barrier makes interruption
# recovery deterministic without affecting normal installs. Whether a specific
# pair is admissible is decided where the truth lives — the packaged releases
# and `release_handler` refuse at check_install when no relup can be produced.
#
# Build the candidate with both variables set; build a plain release with both
# unset.
(fn ->
   to = System.get_env("RELUP_TO")
   from = System.get_env("RELUP_FROM")
   vsn = ~r/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/

   steps = [
     {:update, OpenAgents.ReleaseState, {:advanced, []}},
     {:apply, {OpenAgents.ReleaseState, :install_barrier, []}},
     {:load_module, OpenAgents.BuildInfo}
   ]

   cond do
     is_binary(to) and is_binary(from) and Regex.match?(vsn, to) and
         Regex.match?(vsn, from) and from != to ->
       {String.to_charlist(to), [{String.to_charlist(from), steps}],
        [{String.to_charlist(from), steps}]}

     is_nil(to) and is_nil(from) ->
       {String.to_charlist(System.get_env("OPENAGENTS_RELEASE_VSN", "0.2.0")), [], []}

     true ->
       raise "RELUP_FROM and RELUP_TO must be distinct X.Y.Z versions"
   end
 end).()
