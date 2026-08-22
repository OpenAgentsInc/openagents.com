# Hot-upgrade instructions for the :openagents app, for one concrete pair.
#
# `:systools.make_relup/4` copies an appup into the relup verbatim and never
# compares module contents, so a constant instruction list would install only
# the modules it names and leave the rest of the node on the old revision while
# `BuildInfo.revision/0` reported the new one. `OpenAgents.Release.Appup`
# therefore derives the instruction list from the two builds' compiled modules.
#
# Set RELUP_FROM, RELUP_TO, RELUP_FROM_EBIN, RELUP_FROM_STATE, and
# RELUP_TO_STATE to build a relup candidate. RELUP_FROM_EBIN must be a copy of
# the older build's `_build/<env>/lib/openagents/ebin` directory, taken before
# the newer build overwrites it; RELUP_TO_EBIN defaults to this build's own
# compile path. Leave RELUP_FROM and RELUP_TO unset to build a plain release.
# Anything in between fails the build rather than emitting an instruction list
# that cannot be trusted.
(fn ->
   to = System.get_env("RELUP_TO")
   from = System.get_env("RELUP_FROM")

   cond do
     is_binary(to) and is_binary(from) ->
       from_ebin =
         System.get_env("RELUP_FROM_EBIN") ||
           raise "RELUP_FROM_EBIN must name the from-build's openagents ebin directory"

       schema = fn name ->
         case System.get_env(name) do
           value when value in ["1", "2"] -> String.to_integer(value)
           _other -> raise "#{name} must be 1 or 2"
         end
       end

       OpenAgents.Release.Appup.build(
         from_version: from,
         to_version: to,
         from_ebin: Path.expand(from_ebin),
         to_ebin: System.get_env("RELUP_TO_EBIN", Mix.Project.compile_path()),
         from_state_version: schema.("RELUP_FROM_STATE"),
         to_state_version: schema.("RELUP_TO_STATE")
       )

     is_nil(to) and is_nil(from) ->
       {String.to_charlist(System.get_env("OPENAGENTS_RELEASE_VSN", "0.2.0")), [], []}

     true ->
       raise "RELUP_FROM and RELUP_TO must be set together"
   end
 end).()
