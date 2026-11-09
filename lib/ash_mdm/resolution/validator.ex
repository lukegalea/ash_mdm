# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Resolution.Validator do
  @moduledoc """
  The activate gate for a resolver. A resolver that cannot be planned with is
  refused here, so the planner can trust the rows it is given.
  """

  alias AshMdm.Mapping.Validator, as: MappingValidator
  alias AshMdm.Resolution

  @spec findings(map()) :: %{errors: [map()], warnings: [map()]}
  def findings(%{golden_resource: golden_resource} = resolver) do
    produces = resolver[:produces]
    requires = resolver[:requires] || []

    errors =
      [
        MappingValidator.unknown_target_findings(golden_resource),
        kind(resolver[:kind]),
        list(:produces, produces),
        list(:requires, requires),
        empty_produces(produces),
        overlap(produces, requires),
        cost(resolver[:cost_rank]),
        reference(resolver[:reference]),
        unknown_attributes(golden_resource, produces, requires)
      ]
      |> Enum.concat()

    %{errors: errors, warnings: []}
  end

  defp kind(kind) do
    if kind in Resolution.kinds(), do: [], else: [%{check: :unknown_kind, kind: inspect(kind)}]
  end

  defp list(field, value) when is_nil(value) or (is_list(value) and value == []) do
    _ = field
    []
  end

  defp list(field, value) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) and String.trim(&1) != "")),
      do: [],
      else: [%{check: :"bad_#{field}"}]
  end

  defp list(field, _value), do: [%{check: :"bad_#{field}"}]

  defp empty_produces(produces) when produces in [nil, []], do: [%{check: :empty_produces}]
  defp empty_produces(_produces), do: []

  defp overlap(produces, requires) when is_list(produces) and is_list(requires) do
    for attribute <- Enum.uniq(produces),
        attribute in requires,
        do: %{check: :produces_and_requires, attribute: attribute}
  end

  defp overlap(_produces, _requires), do: []

  defp cost(cost) when is_integer(cost) and cost > 0, do: []
  defp cost(cost), do: [%{check: :bad_cost_rank, cost_rank: inspect(cost)}]

  defp reference(reference) when is_map(reference) and map_size(reference) > 0, do: []
  defp reference(_reference), do: [%{check: :bad_reference}]

  defp unknown_attributes(golden_resource, produces, requires) do
    with {:ok, attributes} <- MappingValidator.accountable_attributes(golden_resource),
         true <- is_list(produces) and is_list(requires) do
      known = MapSet.new(attributes, &to_string(&1.name))

      (produces ++ requires)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&%{check: :unknown_attribute, attribute: &1})
    else
      _ -> []
    end
  end
end
