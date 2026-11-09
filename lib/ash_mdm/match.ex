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

  Missing values on either side contribute 0 and the rule's entry gains
  `"missing" => true`, so a calibration can tell "no data" from "disagreed".
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
  defp part(contribution, weight), do: %{"w" => weight, "c" => contribution}

  defp contribution(%{"kind" => "exact", "fields" => fields} = rule, staged, golden) do
    values = Enum.map(fields, &{normalized(staged[&1], rule), normalized(golden[&1], rule)})

    cond do
      Enum.any?(values, fn {s, g} -> is_nil(s) or is_nil(g) end) -> :missing
      Enum.all?(values, fn {s, g} -> s == g end) -> Decimal.new(1)
      true -> Decimal.new(0)
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

  defp contribution(_unknown_kind, _staged, _golden), do: Decimal.new(0)

  defp normalized(nil, _rule), do: nil

  defp normalized(value, rule) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> AshMdm.Standardize.run(rule["standardize"] || [])
    |> blank_to_nil()
  end

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
