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

    * `most_recent`  — the record whose `observed_at` is latest, to the microsecond
    * `source_rank`  — earliest source in the policy's `source_rank` list.
      Every record's `source` must be a real source name: one the list does
      not name ranks last, so placeholders tie and the first record wins
    * `origin_rank`  — earliest origin kind in the policy's `origin_rank`
      list, for records that carry `origin` (see `AshMdm.Assertions`)
    * `most_complete` — the record with the fewest nil attributes, or the
      highest `completeness` when a record carries one (see `AshMdm.Assertions`)
    * `non_null`     — first non-nil in record order (the default)
    * `steward_override` — the record the steward nominated; recorded as
      provenance, resolved by the caller passing that record first

  Every candidate record is `%{record: term(), source: String.t(),
  observed_at: DateTime.t() | nil, attributes: map()}`.
  """

  @strategies ~w(most_recent source_rank origin_rank most_complete non_null steward_override)

  def strategies, do: @strategies

  @spec resolve(map(), [map()]) :: %{merged: map(), provenance: map()}
  def resolve(policy, records) when is_list(records) and records != [] do
    policy |> resolve_with_winners(records) |> Map.delete(:winners)
  end

  @doc """
  `resolve/2`, plus `winners`: the record that won each attribute, for a
  caller whose provenance needs more than the source name.
  """
  @spec resolve_with_winners(map(), [map()]) :: %{
          merged: map(),
          provenance: map(),
          winners: map()
        }
  def resolve_with_winners(policy, records) when is_list(records) and records != [] do
    attributes = policy["attributes"] || %{}
    default = policy["default"] || "non_null"
    ranks = %{source: policy["source_rank"] || [], origin: policy["origin_rank"] || []}

    keys =
      records
      |> Enum.flat_map(&Map.keys(&1.attributes))
      |> Enum.uniq()

    Enum.reduce(keys, %{merged: %{}, provenance: %{}, winners: %{}}, fn key, acc ->
      strategy = get_strategy(attributes, key, default)

      case pick(key, strategy, ranks, records) do
        nil ->
          put_in(acc, [:provenance, key], %{"strategy" => strategy, "source" => nil})

        rec ->
          acc
          |> put_in([:merged, key], rec.attributes[key])
          |> put_in([:provenance, key], %{"source" => rec.source, "strategy" => strategy})
          |> put_in([:winners, key], rec)
      end
    end)
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
  defp pick(key, strategy, ranks, records) do
    competing = Enum.filter(records, &(not is_nil(rec_get(records, &1, key))))

    case strategy do
      "most_recent" ->
        competing
        |> Enum.max_by(&observed_unix(&1, records), fn -> nil end)

      "source_rank" ->
        competing |> Enum.min_by(&rank_of(&1.source, ranks.source), fn -> nil end)

      "origin_rank" ->
        competing
        |> Enum.min_by(&rank_of(to_string(Map.get(&1, :origin)), ranks.origin), fn -> nil end)

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
    do: (rec.observed_at && DateTime.to_unix(rec.observed_at, :microsecond)) || 0

  defp rank_of(source, source_rank) do
    case Enum.find_index(source_rank, &(&1 == source)) do
      nil -> length(source_rank) + 1
      idx -> idx
    end
  end

  defp completeness(%{completeness: count}) when is_integer(count), do: count

  defp completeness(rec) do
    rec.attributes |> Map.values() |> Enum.count(&(not is_nil(&1)))
  end
end
