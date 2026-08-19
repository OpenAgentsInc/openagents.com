defmodule OpenAgents.Modules.SurfacePolicy do
  @moduledoc "Finite capability, effect, approval, and executor contracts for every Sarah surface."

  alias OpenAgents.Modules.Artifact
  alias OpenAgents.Tools.ExecutionContext

  @contracts %{
    "text" => %{
      kinds: ~w(tool model_executor agent_executor plugin),
      effects: ~w(read_only reversible_write external_effect)
    },
    "voice" => %{
      kinds: ~w(tool model_executor),
      effects: ~w(read_only reversible_write external_effect)
    },
    "search" => %{kinds: ~w(tool model_executor), effects: ~w(read_only)},
    "computer" => %{
      kinds: ~w(tool agent_executor),
      effects: ~w(read_only reversible_write external_effect)
    },
    "repository" => %{
      kinds: ~w(tool agent_executor plugin),
      effects: ~w(read_only reversible_write external_effect)
    },
    "mcp" => %{
      kinds: ~w(tool agent_executor plugin),
      effects: ~w(read_only reversible_write external_effect)
    },
    "agent" => %{
      kinds: ~w(tool agent_executor),
      effects: ~w(read_only reversible_write external_effect)
    }
  }

  def surfaces, do: @contracts |> Map.keys() |> Enum.sort()
  def contracts, do: @contracts

  def validate_artifact(%Artifact{} = artifact) do
    surfaces = artifact.facets["surfaces"]

    cond do
      not is_list(surfaces) or surfaces == [] or length(surfaces) > map_size(@contracts) ->
        {:error, :module_surfaces_invalid}

      surfaces != Enum.sort(Enum.uniq(surfaces)) ->
        {:error, :module_surfaces_invalid}

      Enum.any?(surfaces, &(not Map.has_key?(@contracts, &1))) ->
        {:error, :module_surface_unknown}

      Enum.any?(surfaces, fn surface ->
        contract = Map.fetch!(@contracts, surface)
        artifact.kind not in contract.kinds or artifact.side_effect_class not in contract.effects
      end) ->
        {:error, :module_surface_contract_refused}

      artifact.side_effect_class == "external_effect" and
          artifact.approval_class not in ["external_confirmation", "explicit_operator_approval"] ->
        {:error, :module_external_approval_required}

      artifact.side_effect_class == "reversible_write" and
          artifact.approval_class != "exact_current_user_consent" ->
        {:error, :module_approval_mismatch}

      artifact.facets["approval_enforcement"] not in ["host_receipt", "executor_consent"] ->
        {:error, :module_approval_enforcement_invalid}

      true ->
        :ok
    end
  end

  def authorize_route(%Artifact{} = artifact, surface) do
    with true <- surface in surfaces() or {:error, :surface_unknown},
         true <- surface in artifact.facets["surfaces"] or {:error, :surface_not_admitted},
         :ok <- validate_artifact(artifact) do
      :ok
    end
  end

  def authorize_execution(%Artifact{} = artifact, %ExecutionContext{} = context) do
    with :ok <- authorize_route(artifact, context.surface),
         :ok <- approval(artifact, context) do
      :ok
    end
  end

  def require_target_receipt?(%Artifact{side_effect_class: effect}), do: effect != "read_only"

  defp approval(%Artifact{side_effect_class: "read_only"}, _context), do: :ok

  defp approval(
         %Artifact{
           side_effect_class: "reversible_write",
           facets: %{"approval_enforcement" => "executor_consent"}
         },
         _context
       ),
       do: :ok

  defp approval(%Artifact{} = artifact, context) do
    expected_class = artifact.approval_class

    valid? =
      Enum.any?(context.approval_receipts, fn receipt ->
        is_map(receipt) and receipt["schema"] == "sarah.module_approval.v1" and
          receipt["approval_class"] == expected_class and
          receipt["module_id"] == artifact.module_id and
          receipt["version"] == artifact.version and receipt["scope_ref"] == context.scope_ref and
          receipt["explicit"] == true and receipt["actor_type"] in ["person", "operator"] and
          is_binary(receipt["receipt_ref"]) and byte_size(receipt["receipt_ref"]) in 1..256
      end)

    if valid?, do: :ok, else: {:error, :module_approval_required}
  end
end
