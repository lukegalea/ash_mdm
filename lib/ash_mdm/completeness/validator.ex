# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Completeness.Validator do
  @moduledoc """
  The activate gate for a completeness profile. Same contract as
  `AshMdm.Mapping.Validator`: every public attribute of the golden is
  accounted for, and an entry without a reason is not an account.
  """

  alias AshMdm.Completeness
  alias AshMdm.Mapping.Validator, as: MappingValidator

  @spec findings(map()) :: %{errors: [map()], warnings: [map()]}
  def findings(%{golden_resource: golden_resource, requirements: requirements}) do
    requirements = requirements || []
    {entries, malformed} = Enum.split_with(requirements, &is_map/1)

    errors =
      [
        MappingValidator.unknown_target_findings(golden_resource),
        Enum.map(malformed, &%{check: :malformed_requirement, entry: inspect(&1)}),
        accounting(entries, MappingValidator.accountable_attributes(golden_resource)),
        duplicates(entries),
        Enum.flat_map(entries, &entry_problems/1)
      ]
      |> Enum.concat()

    %{errors: errors, warnings: []}
  end

  defp accounting(entries, {:ok, attributes}) do
    known = MapSet.new(attributes, &to_string(&1.name))
    declared = MapSet.new(entries, & &1["attribute"])

    unaccounted =
      for name <- MapSet.difference(known, declared),
          do: %{check: :unaccounted_attribute, attribute: name}

    unknown =
      for name <- MapSet.difference(declared, known),
          do: %{check: :unknown_attribute, attribute: name}

    unaccounted ++ unknown
  end

  defp accounting(_entries, _unknown_target), do: []

  defp duplicates(entries) do
    entries
    |> Enum.frequencies_by(& &1["attribute"])
    |> Enum.filter(fn {_attribute, count} -> count > 1 end)
    |> Enum.map(fn {attribute, _count} ->
      %{check: :duplicate_attribute, attribute: attribute}
    end)
  end

  defp entry_problems(entry) do
    attribute = entry["attribute"]

    [
      if(entry["need"] not in Completeness.needs(), do: :unknown_need),
      if(blank?(entry["because"]), do: :without_because),
      if(bad_age?(entry["max_age_days"]), do: :bad_max_age),
      if(bad_origins?(entry["accepted_origins"]), do: :bad_accepted_origins),
      if(not is_nil(entry["material"]) and not is_boolean(entry["material"]), do: :bad_material),
      if(entry["need"] != "required" and qualified?(entry), do: :qualifier_on_unrequired)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&%{check: &1, attribute: attribute})
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  defp bad_age?(nil), do: false
  defp bad_age?(days), do: not (is_integer(days) and days > 0)

  defp bad_origins?(nil), do: false

  defp bad_origins?(origins) when is_list(origins) and origins != [] do
    known = Enum.map(AshMdm.Assertions.rankable_origin_kinds(), &to_string/1)
    Enum.any?(origins, &(&1 not in known))
  end

  defp bad_origins?(_), do: true

  defp qualified?(entry) do
    entry["material"] == true or not is_nil(entry["max_age_days"]) or
      not is_nil(entry["accepted_origins"])
  end
end
