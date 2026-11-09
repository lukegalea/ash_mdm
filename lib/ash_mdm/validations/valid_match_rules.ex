# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Validations.ValidMatchRules do
  @moduledoc """
  Activation gate for a MatchRuleSet's rules. Scoring is a fold over data, so
  a typo doesn't crash: an unknown kind scores 0 forever and a bad weight
  quietly becomes 1.0. Both are refused here, as unknown survivorship
  strategies are.
  """

  use Ash.Resource.Validation

  alias AshMdm.Standardize

  @kinds ~w(exact fuzzy)
  @algorithms [nil, "levenshtein", "jaro"]

  @impl true
  def validate(changeset, _opts, _context) do
    rules = Ash.Changeset.get_attribute(changeset, :rules) || []

    case Enum.flat_map(rules, &problems/1) ++ duplicate_names(rules) do
      [] -> :ok
      found -> {:error, field: :rules, message: "invalid match rules: #{Enum.join(found, "; ")}"}
    end
  end

  defp problems(rule) when is_map(rule) do
    name = rule["name"]

    [
      if(not (is_binary(name) and name != ""), do: "a rule has no name"),
      if(rule["kind"] not in @kinds, do: "unknown kind #{inspect(rule["kind"])}"),
      kind_problem(rule),
      if(bad_weight?(Map.fetch(rule, "weight")), do: "bad weight #{inspect(rule["weight"])}"),
      standardize_problem(rule["standardize"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&"#{inspect(name)}: #{&1}")
  end

  defp problems(rule), do: ["not a rule: #{inspect(rule)}"]

  defp kind_problem(%{"kind" => "exact"} = rule) do
    case rule["fields"] do
      [_ | _] = fields -> if(not Enum.all?(fields, &present?/1), do: "a blank field")
      _ -> "exact needs fields"
    end
  end

  defp kind_problem(%{"kind" => "fuzzy"} = rule) do
    cond do
      not present?(rule["field"]) -> "fuzzy needs a field"
      rule["algorithm"] not in @algorithms -> "unknown algorithm #{inspect(rule["algorithm"])}"
      true -> nil
    end
  end

  defp kind_problem(_rule), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp bad_weight?(:error), do: false
  defp bad_weight?({:ok, weight}), do: not (is_number(weight) and weight > 0)

  defp standardize_problem(nil), do: nil

  defp standardize_problem(names) when is_list(names) do
    case names -- Standardize.standardizers() do
      [] -> nil
      unknown -> "unknown standardizers #{inspect(unknown)}"
    end
  end

  defp standardize_problem(other), do: "standardize must be a list, got #{inspect(other)}"

  # The explanation is keyed by name, so a second rule would overwrite the
  # first one's contribution.
  defp duplicate_names(rules) do
    rules
    |> Enum.filter(&is_map/1)
    |> Enum.frequencies_by(& &1["name"])
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> "duplicate rule name #{inspect(name)}" end)
  end
end
