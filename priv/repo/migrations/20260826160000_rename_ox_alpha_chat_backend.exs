defmodule OpenAgents.Repo.Migrations.RenameOxAlphaChatBackend do
  use Ecto.Migration

  # Rename the recorded `ox-alpha` chat backend to `glm-5.3-flash`.
  #
  # `stealth/ox-alpha` was GLM 5.3 Flash under its pre-launch name; OpenRouter
  # answers that slug with a 404 saying so. The backend was renamed rather than
  # replaced, so the rows it wrote describe the same model under an old name.
  #
  # Leaving them would lose them. `OpenAgents.Chat.AccountTurns` replays a
  # conversation's history only into the backend that wrote it, matching on
  # this column, so a row still reading `ox-alpha` would never replay again —
  # the transcript would silently shorten rather than fail.

  def up do
    execute("UPDATE account_chat_runs SET backend = 'glm-5.3-flash' WHERE backend = 'ox-alpha'")
  end

  def down do
    execute("UPDATE account_chat_runs SET backend = 'ox-alpha' WHERE backend = 'glm-5.3-flash'")
  end
end
