# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Tuning do
  @moduledoc """
  Proposes rule weights from pairs a person has already judged. Pure, and a
  proposal only: a host writes the result as a new draft rule set version, a
  person activates it, and the new content hash means the bands are earned
  again.

  Each rule's weight is its Fellegi-Sunter agreement weight, `log2(m / u)`:

    * `m`: how often the rule agrees on pairs judged a match;
    * `u`: how often it agrees on pairs judged not a match.

  A rule "agrees" when its contribution is at least 0.85. A rule that had no
  data for a pair (the explanation's `"missing"`) says nothing about that
  pair. An explanation written before that flag existed reads as a
  disagreement, so pass pairs scored by the current rule set version.

  Each rate is smoothed by half a pair, so a rule that was never wrong still
  gets a finite weight. A rule with fewer than 10 labelled pairs of either
  kind keeps what it had: a weight learned from a handful of verdicts is
  worse than a stated one.

  A rule that agrees on non-matches as often as on matches earns a weight at
  or below zero. Scoring needs a positive weight, so it is floored at 0.01
  and reported `:floored`, which is a person's cue to look at that rule.
  """

  @agreement Decimal.new("0.85")
  @min_labels 10
  @floor 0.01

  @type labelled :: %{explanation: map(), verdict: atom()}

  @doc """
  Takes the current rules and judged pairs, and returns
  `%{rules: [...], report: [...]}` in rule order. Verdicts other than
  `:match` and `:non_match` are ignored. A report entry's `status` is
  `:proposed`, `:floored` or `:insufficient_labels`.
  """
  @spec propose([map()], [labelled()]) :: %{rules: [map()], report: [map()]}
  def propose(rules, labelled) when is_list(rules) and is_list(labelled) do
    {matches, non_matches} =
      labelled
      |> Enum.filter(&(&1.verdict in [:match, :non_match]))
      |> Enum.split_with(&(&1.verdict == :match))

    {proposed, report} =
      rules
      |> Enum.map(&tune(&1, tally(&1, matches), tally(&1, non_matches)))
      |> Enum.unzip()

    %{rules: proposed, report: report}
  end

  defp tally(rule, pairs) do
    observed =
      pairs
      |> Enum.map(& &1.explanation[rule["name"]])
      |> Enum.filter(&observed?/1)

    {Enum.count(observed, &agrees?/1), length(observed)}
  end

  defp observed?(%{"missing" => true}), do: false
  defp observed?(entry), do: is_map(entry)

  defp agrees?(%{"c" => contribution}) do
    Decimal.compare(to_decimal(contribution), @agreement) != :lt
  end

  # Decimal in memory, a string once the explanation has been through JSON.
  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp tune(rule, {_, match_count} = m, {_, non_match_count} = u)
       when match_count < @min_labels or non_match_count < @min_labels do
    {rule, entry(rule, :insufficient_labels, rule["weight"], m, u)}
  end

  defp tune(rule, m, u) do
    raw = :math.log2(rate(m) / rate(u))
    weight = max(raw, @floor) |> Float.round(4)
    status = if(raw < @floor, do: :floored, else: :proposed)

    {Map.put(rule, "weight", weight), entry(rule, status, weight, m, u)}
  end

  defp rate({agreed, observed}), do: (agreed + 0.5) / (observed + 1)

  defp entry(rule, status, weight_after, {_, matches} = m, {_, non_matches} = u) do
    %{
      rule: rule["name"],
      status: status,
      weight_before: rule["weight"],
      weight_after: weight_after,
      m: Float.round(rate(m), 4),
      u: Float.round(rate(u), 4),
      matches: matches,
      non_matches: non_matches
    }
  end
end
