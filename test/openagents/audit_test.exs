defmodule OpenAgents.AuditTest do
  @moduledoc """
  CANON-002. The audit ledger admits every actor kind the application produces.

  `machine` is one of them. A paired computer that authenticates to the Git
  plane pushes and fetches under `{:machine, id}`, so `audit_events.actor_type`
  really does carry the value and keeps its spelling.

  The population that matters here is not a reading of the `Audit.record!/5`
  call sites: the Git-plane actor is a variable, so scanning the source for a
  literal `{:machine, …}` finds nothing and proves nothing. It comes from
  `OpenAgents.Forge.GitHTTP.audit_actor_kinds/0`, the list that decides what
  `audit_actor/1` can return.
  """
  use OpenAgents.DataCase, async: true

  alias OpenAgents.{Audit, AuditEvent}
  alias OpenAgents.Forge.GitHTTP

  test "every Git-plane principal kind is an accepted audit actor" do
    accepted = MapSet.new(Audit.actor_kinds())

    for kind <- GitHTTP.audit_actor_kinds() do
      assert MapSet.member?(accepted, Atom.to_string(kind)),
             "a #{kind} push would raise inside Audit.record!/5 after the pack is written"
    end
  end

  test "the schema admits exactly the kinds record!/5 accepts" do
    for kind <- Audit.actor_kinds() do
      assert AuditEvent.changeset(%AuditEvent{}, attributes(kind)).valid?,
             "audit_events refuses the declared actor kind #{kind}"
    end

    refute AuditEvent.changeset(%AuditEvent{}, attributes("computer")).valid?
  end

  test "record!/5 writes each declared kind" do
    for kind <- Audit.actor_kinds() do
      event =
        Audit.record!("vocabulary.probe", {String.to_existing_atom(kind), "actor"}, "probe", kind)

      assert event.actor_type == kind
    end

    assert_raise FunctionClauseError, fn ->
      Audit.record!("vocabulary.probe", {:computer, "actor"}, "probe", "computer")
    end
  end

  defp attributes(actor_type) do
    %{
      event_type: "vocabulary.probe",
      actor_type: actor_type,
      actor_id: "actor",
      subject_type: "probe",
      subject_id: actor_type,
      metadata: %{}
    }
  end
end
