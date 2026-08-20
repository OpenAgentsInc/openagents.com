defmodule OpenAgents.ShadowPrograms.Provider do
  @moduledoc "No-effect provider boundary for one typed shadow inference."

  @callback evaluate(
              OpenAgents.ProgramArtifacts.Artifact.t(),
              OpenAgents.ShadowPrograms.Signature.t(),
              map(),
              pos_integer()
            ) ::
              {:ok,
               %{
                 output: map(),
                 response_id: String.t(),
                 usage: map()
               }}
              | {:error, atom() | tuple()}
end
