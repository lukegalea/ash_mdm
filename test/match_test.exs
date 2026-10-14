# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.MatchTest do
  @moduledoc "The scoring fold: rules are data, no thresholds in code."

  use ExUnit.Case, async: true

  import AshMdm.TestHelpers

  alias AshMdm.Match

  @rules [
    %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
    %{
      "name" => "name_fuzzy",
      "kind" => "fuzzy",
      "field" => "name",
      "algorithm" => "levenshtein",
      "weight" => 0.5
    }
  ]

  test "identical pair scores 1.0" do
    staged = %{"email" => "a@x.io", "name" => "Ann"}
    golden = %{"email" => "a@x.io", "name" => "Ann"}

    {score, explanation} = Match.score(@rules, staged, golden)
    assert Decimal.eq?(score, Decimal.new(1))
    assert explanation["email_exact"]["c"] == Decimal.new(1)
  end

  test "different values contribute 0" do
    {score, _} =
      Match.score(@rules, %{"email" => "a@x.io", "name" => "Ann"}, %{
        "email" => "b@y.io",
        "name" => "Bob"
      })

    refute Decimal.eq?(score, Decimal.new(1))
    assert Decimal.lt?(score, Decimal.new("0.5"))
  end

  test "missing values contribute 0, never evidence of a match" do
    {score, explanation} =
      Match.score(@rules, %{"name" => "Ann"}, %{"email" => "a@x.io", "name" => "Ann"})

    assert explanation["email_exact"]["c"] == Decimal.new(0)
    assert Decimal.lt?(score, Decimal.new(1))
  end

  test "weights normalize the sum" do
    rules = [
      %{"name" => "a", "kind" => "exact", "fields" => ["email"], "weight" => 3.0},
      %{"name" => "b", "kind" => "exact", "fields" => ["name"], "weight" => 1.0}
    ]

    # a matches (3), b does not (0): 3/4.
    {score, _} =
      Match.score(rules, %{"email" => "x", "name" => "1"}, %{"email" => "x", "name" => "2"})

    assert Decimal.eq?(score, Decimal.new("0.75"))
  end

  test "levenshtein distance is the textbook function" do
    assert Match.levenshtein_for_test("kitten", "sitting") == 3
    assert Match.levenshtein_for_test("ann existing", "ann existing-smith") == 6
    assert Match.levenshtein_for_test("", "abc") == 3
    assert Match.levenshtein_for_test("same", "same") == 0
  end

  test "levenshtein similarity is graded, not binary" do
    rules = [%{"name" => "n", "kind" => "fuzzy", "field" => "name", "weight" => 1.0}]

    {close, _} = Match.score(rules, %{"name" => "Jonathon"}, %{"name" => "Jonathon Smith"})
    {far, _} = Match.score(rules, %{"name" => "Jonathon"}, %{"name" => "Xylophone"})

    assert Decimal.gt?(close, far)
    assert Decimal.gt?(close, Decimal.new(0))
  end
end
