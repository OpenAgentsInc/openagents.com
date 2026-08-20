# Supported hot-upgrade instructions for the :openagents app. Release proofs
# build 0.1.0 and 0.2.0 explicitly. The advanced update runs code_change/3 in
# both directions, and the optional barrier makes interruption recovery
# deterministic without affecting normal installs.
(fn ->
   to = System.get_env("RELUP_TO")
   from = System.get_env("RELUP_FROM")

   case {to, from} do
     {"0.2.0", "0.1.0"} ->
       steps = [
         {:update, OpenAgents.ReleaseState, {:advanced, []}},
         {:apply, {OpenAgents.ReleaseState, :install_barrier, []}},
         {:load_module, OpenAgents.BuildInfo}
       ]

       {~c"0.2.0", [{~c"0.1.0", steps}], [{~c"0.1.0", steps}]}

     {nil, nil} ->
       {String.to_charlist(System.get_env("OPENAGENTS_RELEASE_VSN", "0.2.0")), [], []}

     _unsupported ->
       raise "RELUP_FROM and RELUP_TO must select the supported 0.1.0 to 0.2.0 transition"
   end
 end).()
