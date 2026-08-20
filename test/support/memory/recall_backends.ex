defmodule OpenAgents.Memory.UnavailableRecallBackend do
  @moduledoc false

  def search_page(_conversation, _snapshot, _query, _options),
    do: {:error, :lexical_unavailable}
end

defmodule OpenAgents.Memory.BlockingRecallBackend do
  @moduledoc false

  def search_page(_conversation, _snapshot, _query, _options) do
    observer = Application.fetch_env!(:openagents, :test_recall_backend_observer)
    send(observer, {:recall_backend_started, self()})

    receive do
      :release_recall_backend -> {:error, :lexical_unavailable}
    after
      10_000 -> {:error, :lexical_unavailable}
    end
  end
end
