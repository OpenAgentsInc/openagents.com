# Hot-upgrade instructions for the :openagents app. A pure code swap of one
# module uses {:load_module, Mod} (no state migration — the safest relup); a
# stateful server change would use {:update, Mod, {:advanced, []}} to run
# code_change/3.
# RELUP_TO/RELUP_FROM drive a two-build relup; unset => a plain build with no steps.
(fn ->
   to = System.get_env("RELUP_TO")
   from = System.get_env("RELUP_FROM")

   if is_binary(to) and is_binary(from) do
     step = [{:load_module, OpenAgents.BuildInfo}]
     {String.to_charlist(to), [{String.to_charlist(from), step}], [{String.to_charlist(from), step}]}
   else
     {String.to_charlist(System.get_env("OPENAGENTS_RELEASE_VSN", "0.1.0")), [], []}
   end
 end).()
