# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Survivorship do
  @moduledoc """
  The survivorship fold (ADR 0050 §7): given a policy and the competing
  records, produce the merged attribute set plus per-attribute provenance
  — which source row won which field. A pure fold, unit-tested against
  fixtures, never clicked.

  Policy shape (string-keyed JSON on the host's MatchRuleSet):

      %{"default" => "non_null",
        "attributes" => %{"name" => %{"strategy" => "source_rank"},
                          "email" => %{"strategy" => "most_recent"}},
        "source_rank" => ["salesforce", "manual_csv"]}

  Strategies:

    * `most_recent`  — the record whose `observed_at` is latest
    * `source_rank`  — earliest source in the policy's `source_rank` list
    * `most_complete` — the record with the fewest nil attributes
    * `non_null`     — first non-nil in record order (the default)
    * `steward_override` — the record the steward nominated; recorded as
      provenance, resolved by the caller passing that record first

  Every candidate record is `%{record: term(), source: String.t(),
  observed_at: DateTime.t() | nil, attributes: map()}`.
  """

  @strategies ~w(most_recent source_rank most_complete non_null steward_override)

  def strategies, do: @strategies

  @spec resolve(map(), [map()]) :: %{merged: map(), provenance: map()}
  def resolve(policy, records) when is_list(records) and records != [] do
    attributes = policy["attributes"] || %{}
    default = policy["default"] || "non_null"
    source_rank = policy["source_rank"] || []

    keys =
      records
      |> Enum.flat_map(&Map.keys(&1.attributes))
      |> Enum.uniq()

    {merged, provenance} =
      Enum.reduce(keys, {%{}, %{}}, fn key, {m, p} ->
        strategy = get_strategy(attributes, key, default)
        winner = pick(key, strategy, source_rank, records)

        case winner do
          nil ->
            {m, Map.put(p, key, %{"strategy" => strategy, "source" => nil})}

          rec ->
            {Map.put(m, key, rec.attributes[key]),
             Map.put(p, key, %{"source" => rec.source, "strategy" => strategy})}
        end
      end)

    %{merged: merged, provenance: provenance}
  end

  defp get_strategy(attributes, key, default) do
    case attributes[key] do
      %{"strategy" => s} when s in @strategies -> s
      _ -> default
    end
  end

  # Records carrying a NON-NIL value for this key compete; the strategy
  # picks among them. None compete → the attribute stays absent and the
  # provenance records the miss ("no source had a value"), distinguishable
  # from "attribute not considered".
  defp pick(key, strategy, source_rank, records) do
    competing = Enum.filter(records, &(not is_nil(rec_get(records, &1, key))))

    case strategy do
      "most_recent" ->
        competing
        |> Enum.max_by(&(observed_unix(&1, records)), fn -> nil end)

      "source_rank" ->
        competing |> Enum.min_by(&rank_of(&1.source, source_rank), fn -> nil end)

      "most_complete" ->
        competing |> Enum.max_by(&completeness/1, fn -> nil end)

      "non_null" ->
        List.first(competing)

      "steward_override" ->
        List.first(competing)

      _ ->
        nil
    end
  end

  defp rec_get(_records, rec, key), do: rec.attributes[key]

  defp observed_unix(rec, _records),
    do: rec.observed_at && DateTime.to_unix(rec.observed_at) || 0

  defp rank_of(source, source_rank) do
    case Enum.find_index(source_rank, &(&1 == source)) do
      nil -> length(source_rank) + 1
      idx -> idx
    end
  end

  defp completeness(rec) do
    rec.attributes |> Map.values() |> Enum.count(&(not is_nil(&1)))
  end
end
