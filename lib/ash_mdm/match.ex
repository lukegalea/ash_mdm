# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Match do
  @moduledoc """
  Deterministic entity-resolution scoring (ADR 0017 mechanics, kept
  verbatim by ADR 0050): rules are DATA, the score is a pure fold, and no
  threshold lives in code — bands are the host's DMN decision.
  """

  @moduledoc since: "0.1.0"

  @doc """
  Scores one (staged, golden) pair against a rule set's rules and returns
  `{score, explanation}` where score ∈ [0, 1] (normalized by total weight)
  and explanation maps rule name → contribution.

  Rule shapes (string-keyed JSON):

      %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}
      %{"name" => "name_fuzzy", "kind" => "fuzzy", "field" => "name",
        "algorithm" => "levenshtein" | "jaro", "weight" => 0.5,
        "standardize" => ["unaccent", "legal_suffix"]}

  `standardize` is optional and runs after trim and lowercase; see
  `AshMdm.Standardize`.

  An `overlap` rule compares a list-valued field as a set, for evidence such
  as two people attending the same meetings:

      %{"name" => "shared_meetings", "kind" => "overlap", "field" => "meeting_ids",
        "measure" => "count", "threshold" => 2, "weight" => 1.0}
      %{"name" => "shared_threads", "kind" => "overlap", "field" => "thread_ids",
        "measure" => "jaccard", "threshold" => 0.5}

  Each item is trimmed, lowercased and standardized like a field value, blanks
  are dropped and duplicates collapse. `"measure"` is `"count"` (at least
  `threshold` items in common, a whole number of 1 or more) or `"jaccard"`
  (shared items over all items, at least `threshold`, a number above 0 and up
  to 1). The rule contributes 1 when the threshold is met and 0 when it is
  not, and its explanation entry carries `"detail"`: `"measure"`, `"threshold"`,
  `"shared"`, `"union"` and `"value"`. An empty or absent list on either side
  is `"missing"`: two people with no recorded meetings are not evidence of
  anything.

  Missing values on either side contribute 0 and the rule's entry gains
  `"missing" => true`, so a calibration can tell "no data" from "disagreed". An
  `exact` rule over several fields disagrees if any field both sides state
  differs, even if another is missing.
  Absence is never evidence of a match, and a blank or whitespace-only value,
  including one a standardizer has emptied, is absence.
  """
  @spec score([map()], map(), map()) :: {Decimal.t(), map()}
  def score(rules, staged_map, golden_map) when is_list(rules) do
    {total_weight, parts} =
      Enum.reduce(rules, {Decimal.new(0), %{}}, fn rule, {w, exp} ->
        rule_weight = Decimal.from_float(rule_weight(rule) / 1)
        part = rule |> contribution(staged_map, golden_map) |> part(rule_weight)

        {Decimal.add(w, rule_weight), Map.put(exp, rule["name"], part)}
      end)

    score =
      if Decimal.eq?(total_weight, 0) do
        Decimal.new(0)
      else
        Enum.reduce(parts, Decimal.new(0), fn {_name, %{"w" => w, "c" => c}}, acc ->
          Decimal.add(acc, Decimal.mult(w, c))
        end)
        |> Decimal.div(total_weight)
      end

    {score, parts}
  end

  defp rule_weight(%{"weight" => w}) when is_number(w) and w > 0, do: w * 1.0
  defp rule_weight(_), do: 1.0

  defp part(:missing, weight), do: %{"w" => weight, "c" => Decimal.new(0), "missing" => true}

  defp part({:detail, contribution, detail}, weight),
    do: %{"w" => weight, "c" => contribution, "detail" => detail}

  defp part(contribution, weight), do: %{"w" => weight, "c" => contribution}

  defp contribution(%{"kind" => "exact", "fields" => fields} = rule, staged, golden) do
    values = Enum.map(fields, &{normalized(staged[&1], rule), normalized(golden[&1], rule)})

    # A field both sides state and disagree on settles it, whatever else is
    # blank: "missing" is for a pair the rule could not judge.
    cond do
      Enum.any?(values, fn {s, g} -> present?(s) and present?(g) and s != g end) -> Decimal.new(0)
      Enum.any?(values, fn {s, g} -> is_nil(s) or is_nil(g) end) -> :missing
      true -> Decimal.new(1)
    end
  end

  defp contribution(%{"kind" => "fuzzy", "field" => field} = rule, staged, golden) do
    s = normalized(staged[field], rule)
    g = normalized(golden[field], rule)

    cond do
      is_nil(s) or is_nil(g) ->
        :missing

      s == g ->
        Decimal.new(1)

      true ->
        similarity(s, g, rule["algorithm"] || "levenshtein")
    end
  end

  defp contribution(%{"kind" => "overlap", "field" => field} = rule, staged, golden) do
    s = item_set(staged[field], rule)
    g = item_set(golden[field], rule)

    if MapSet.size(s) == 0 or MapSet.size(g) == 0 do
      :missing
    else
      shared = s |> MapSet.intersection(g) |> MapSet.size()
      union = MapSet.size(s) + MapSet.size(g) - shared
      measure = rule["measure"] || "count"
      value = if measure == "jaccard", do: shared / union, else: shared
      met? = value >= rule["threshold"]

      {:detail, Decimal.new(if(met?, do: 1, else: 0)),
       %{
         "measure" => measure,
         "threshold" => rule["threshold"],
         "shared" => shared,
         "union" => union,
         "value" => value
       }}
    end
  end

  defp contribution(_unknown_kind, _staged, _golden), do: Decimal.new(0)

  defp item_set(value, rule) do
    value
    |> List.wrap()
    |> Enum.map(&compared_value(&1, rule))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc """
  The value a rule compares for one raw field value: trimmed, lowercased,
  run through the rule's `standardize` list (`AshMdm.Standardize`), and
  `nil` when that leaves nothing. This is the exact value `score/3` compares,
  so a host can show what matching saw without re-deriving it.

      iex> AshMdm.Match.compared_value("  Acme Ltd. ", %{"standardize" => ["legal_suffix"]})
      "acme"

      iex> AshMdm.Match.compared_value("   ", %{})
      nil
  """
  @spec compared_value(term(), map()) :: String.t() | nil
  def compared_value(nil, _rule), do: nil

  def compared_value(value, rule) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> AshMdm.Standardize.run(rule["standardize"] || [])
    |> blank_to_nil()
  end

  @doc """
  What each rule compares in one record: one entry per (rule, field), in
  rule order, with the raw value, the compared value (`compared_value/2`),
  the standardizers the rule names, and `"absent"` when the compared value
  is `nil` — the same absence `score/3` reports as `"missing"`.

      iex> AshMdm.Match.compared(
      ...>   [%{"name" => "name_fuzzy", "kind" => "fuzzy", "field" => "name",
      ...>      "standardize" => ["legal_suffix"]}],
      ...>   %{"name" => "Acme Ltd."}
      ...> )
      [%{"rule" => "name_fuzzy", "field" => "name", "raw" => "Acme Ltd.",
         "compared" => "acme", "standardize" => ["legal_suffix"], "absent" => false}]

  An `overlap` rule's compared value is its sorted list of distinct items.
  A rule of an unknown kind compares nothing and has no entry.
  """
  @spec compared([map()], map()) :: [map()]
  def compared(rules, record) when is_list(rules) do
    for rule <- rules, field <- rule_fields(rule) do
      raw = record[field]

      compared = compared_for(rule, raw)

      %{
        "rule" => rule["name"],
        "field" => field,
        "raw" => raw,
        "compared" => compared,
        "standardize" => rule["standardize"] || [],
        "absent" => is_nil(compared)
      }
    end
  end

  defp compared_for(%{"kind" => "overlap"} = rule, raw) do
    case item_set(raw, rule) |> Enum.sort() do
      [] -> nil
      items -> items
    end
  end

  defp compared_for(rule, raw), do: compared_value(raw, rule)

  defp rule_fields(%{"kind" => "exact", "fields" => fields}) when is_list(fields), do: fields
  defp rule_fields(%{"kind" => "fuzzy", "field" => field}), do: [field]
  defp rule_fields(%{"kind" => "overlap", "field" => field}), do: [field]
  defp rule_fields(_unknown_kind), do: []

  defp normalized(value, rule), do: compared_value(value, rule)

  defp present?(value), do: not is_nil(value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp similarity(s, g, "jaro"), do: s |> String.jaro_distance(g) |> Decimal.from_float()

  # True Levenshtein: substitutions count once (a naive myers-script
  # insert/delete count charges two). Small DP fold — the blocker caps
  # pairs at its LIMIT, so quadratic is bounded per staged record.
  defp similarity(s, g, _levenshtein) do
    max_len = max(String.length(s), String.length(g))

    if max_len == 0 do
      Decimal.new(0)
    else
      Decimal.from_float(max(0.0, 1 - levenshtein(s, g) / max_len))
    end
  end

  @doc false
  def levenshtein_for_test(s, g), do: levenshtein(s, g)

  defp levenshtein(s, g) do
    gs = String.graphemes(g)

    initial = Enum.map(0..length(gs), & &1)

    Enum.reduce(String.graphemes(s), initial, fn ch, prev ->
      {_, rev} =
        Enum.reduce(Enum.with_index(gs, 1), {Enum.at(prev, 0) + 1, [Enum.at(prev, 0) + 1]}, fn
          {gc, j}, {_top, acc} ->
            cost = if ch == gc, do: 0, else: 1

            best =
              Enum.min([
                Enum.at(prev, j - 1) + cost,
                Enum.at(prev, j) + 1,
                hd(acc) + 1
              ])

            {best, [best | acc]}
        end)

      Enum.reverse(rev)
    end)
    |> List.last()
  end
end
