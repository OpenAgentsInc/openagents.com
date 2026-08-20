defmodule OpenAgents.Voice.TestCallProvider do
  @behaviour OpenAgents.Voice.CallProvider

  alias OpenAgents.Voice.CallAdmission

  @impl true
  def create(sdp_offer, safety_identifier, config) do
    if observer = Application.get_env(:openagents, :voice_call_test_observer) do
      send(observer, {:voice_call, sdp_offer, safety_identifier, config})
    end

    Application.get_env(
      :openagents,
      :voice_call_test_result,
      {:ok,
       %CallAdmission{
         provider_session_id: "rtc_test",
         answer_sdp: "v=0\r\no=test-answer"
       }}
    )
  end
end
