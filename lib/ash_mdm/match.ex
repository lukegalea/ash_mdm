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
        "algorithm" => "levenshtein" | "jaro", "weight" => 0.5}

  Missing values on either side contribute 0 with the explanation noting
  `"missing"` — absence is never evidence of a match.
  """
  @spec score([map()], map(), map()) :: {Decimal.t(), map()}
  def score(rules, staged_map, golden_map) when is_list(rules) do
    {total_weight, parts} =
      Enum.reduce(rules, {Decimal.new(0), %{}}, fn rule, {w, exp} ->
        rule_weight = Decimal.from_float(rule_weight(rule))
        contribution = contribution(rule, staged_map, golden_map)

        {Decimal.add(w, rule_weight),
         Map.put(exp, rule["name"], %{"w" => rule_weight, "c" => contribution})}
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

  defp contribution(%{"kind" => "exact", "fields" => fields}, staged, golden) do
    values = for f <- fields, into: %{}, do: {f, {normalized(staged[f]), normalized(golden[f])}}

    if Enum.any?(values, fn {_f, {s, g}} -> is_nil(s) or is_nil(g) end) do
      Decimal.new(0)
    else
      if Enum.all?(values, fn {_f, {s, g}} -> s == g end),
        do: Decimal.new(1),
        else: Decimal.new(0)
    end
  end

  defp contribution(%{"kind" => "fuzzy", "field" => field} = rule, staged, golden) do
    s = normalized(staged[field])
    g = normalized(golden[field])

    cond do
      is_nil(s) or is_nil(g) ->
        Decimal.new(0)

      s == g ->
        Decimal.new(1)

      true ->
        similarity(s, g, rule["algorithm"] || "levenshtein")
    end
  end

  defp contribution(_unknown_kind, _staged, _golden), do: Decimal.new(0)

  defp normalized(nil), do: nil
  defp normalized(v), do: v |> to_string() |> String.trim() |> String.downcase()

  defp similarity(s, g, "jaro"), do: s |> String.jaro_distance(g) |> Decimal.from_float()

  defp similarity(s, g, _levenshtein) do
    max_len = max(String.length(s), String.length(g))

    if max_len == 0 do
      Decimal.new(0)
    else
      # myers_difference/2 returns the edit SCRIPT with RUN-LENGTH ops
      # ({:ins, "-smith"} is one op for six characters); the distance is
      # the total length of the non-equal edits.
      dist =
        s
        |> String.myers_difference(g)
        |> Enum.reduce(0, fn
          {:eq, _}, acc -> acc
          {_, text}, acc -> acc + String.length(text)
        end)

      if dist == 0 do
        Decimal.new(1)
      else
        Decimal.from_float(max(0.0, 1 - dist / max_len))
      end
    end
  end
end
