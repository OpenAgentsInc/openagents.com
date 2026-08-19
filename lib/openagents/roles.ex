defmodule OpenAgents.Roles do
  @moduledoc "Admitted Sarah role-program selection."

  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Roles.{Catalog, GeneralCollaborator, Selection, SelectionInput}

  @runtime_compatibility 1
  @authorities ~w(public_default host_surface_policy)
  @surfaces ~w(text voice public)

  @spec default() :: OpenAgents.Roles.Role.t()
  def default, do: GeneralCollaborator.artifact()

  @spec default_selection(String.t(), [String.t()]) :: Selection.t()
  def default_selection(surface \\ "text", available_capabilities \\ []) do
    {:ok, selection} =
      select(%SelectionInput{
        requested_role_id: nil,
        surface: surface,
        authority: "public_default",
        available_capabilities: available_capabilities
      })

    selection
  end

  @spec select(SelectionInput.t()) :: {:ok, Selection.t()} | {:error, atom()}
  def select(%SelectionInput{} = input) do
    with :ok <- validate_input(input),
         {:ok, selected_role, reason} <- choose_role(input) do
      {:ok,
       %Selection{
         role: selected_role,
         surface: input.surface,
         authority: input.authority,
         requested_role_id: input.requested_role_id,
         available_capabilities: Enum.sort(input.available_capabilities),
         reason: reason,
         input_digest: selection_input_digest(input),
         catalog_digest: Catalog.digest()
       }}
    end
  end

  @spec validate_selection(Selection.t()) :: :ok | {:error, atom()}
  def validate_selection(%Selection{} = selection) do
    input = reconstructed_input(selection)

    with {:ok, expected_selection} <- select(input),
         true <- expected_selection == selection do
      :ok
    else
      _invalid -> {:error, :invalid_or_unadmitted_role_selection}
    end
  end

  def validate_selection(_selection), do: {:error, :invalid_or_unadmitted_role_selection}

  defp validate_input(%SelectionInput{} = input) do
    cond do
      input.authority not in @authorities ->
        {:error, :unauthorized_role_selection_source}

      input.surface not in @surfaces ->
        {:error, :unsupported_role_surface}

      not valid_capabilities?(input.available_capabilities) ->
        {:error, :invalid_role_capabilities}

      input.requested_role_id != nil and not is_binary(input.requested_role_id) ->
        {:error, :invalid_requested_role}

      input.requested_role_id != nil and input.authority != "host_surface_policy" ->
        {:error, :requested_role_requires_host_authority}

      true ->
        :ok
    end
  end

  defp choose_role(%SelectionInput{requested_role_id: requested_role_id} = input) do
    requested_role_id = requested_role_id || default().id

    case Catalog.fetch(requested_role_id) do
      {:ok, role} -> choose_catalog_role(role, input)
      {:error, :unknown_role} -> baseline_or_error(input, "requested_role_unknown")
    end
  end

  defp choose_catalog_role(role, input) do
    cond do
      role.status != "admitted" ->
        baseline_or_error(input, "requested_role_inactive")

      input.surface not in role.surfaces ->
        baseline_or_error(input, "requested_role_surface_mismatch")

      not compatible?(role) ->
        baseline_or_error(input, "requested_role_incompatible")

      not capabilities_available?(role, input.available_capabilities) ->
        baseline_or_error(input, "required_capabilities_unavailable")

      input.requested_role_id == nil ->
        {:ok, role, "public_default"}

      true ->
        {:ok, role, "explicit_host_selection"}
    end
  end

  defp baseline_or_error(%SelectionInput{surface: surface} = input, reason) do
    baseline = default()

    if surface in baseline.surfaces and compatible?(baseline) and
         capabilities_available?(baseline, input.available_capabilities) do
      {:ok, baseline, "baseline_fallback:" <> reason}
    else
      {:error, :no_admitted_role_for_surface}
    end
  end

  defp selection_input_digest(input) do
    Canonical.digest!(%{
      "schema" => "sarah.role_selection_input.v1",
      "requested_role_id" => input.requested_role_id,
      "surface" => input.surface,
      "authority" => input.authority,
      "available_capabilities" => Enum.sort(input.available_capabilities)
    })
  end

  defp reconstructed_input(selection) do
    %SelectionInput{
      requested_role_id: selection.requested_role_id,
      surface: selection.surface,
      authority: selection.authority,
      available_capabilities: selection.available_capabilities
    }
  end

  defp compatible?(role),
    do:
      role.compatibility_min <= @runtime_compatibility and
        role.compatibility_max >= @runtime_compatibility

  defp capabilities_available?(role, available_capabilities) do
    available = MapSet.new(available_capabilities)
    Enum.all?(role.required_capabilities, &MapSet.member?(available, &1))
  end

  defp valid_capabilities?(capabilities),
    do:
      is_list(capabilities) and length(capabilities) <= 64 and
        Enum.all?(capabilities, &(is_binary(&1) and &1 != "")) and
        length(capabilities) == MapSet.size(MapSet.new(capabilities))
end
