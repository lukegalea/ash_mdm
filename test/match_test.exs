# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.MatchTest do
  @moduledoc "The scoring fold: rules are data, no thresholds in code."

  use ExUnit.Case, async: true

  import AshMdm.TestHelpers

  alias AshMdm.Match

  doctest AshMdm.Match

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

  test "a composite rule that disagrees on one field is not missing for a blank in another" do
    rule = %{"name" => "both", "kind" => "exact", "fields" => ["a", "b"], "weight" => 1.0}

    {_score, %{"both" => part}} =
      Match.score([rule], %{"a" => "x", "b" => " "}, %{"a" => "y", "b" => "z"})

    assert Decimal.eq?(part["c"], 0)
    refute Map.has_key?(part, "missing")
  end

  test "a composite rule that agrees where it can see is still missing" do
    rule = %{"name" => "both", "kind" => "exact", "fields" => ["a", "b"], "weight" => 1.0}

    {_score, %{"both" => part}} =
      Match.score([rule], %{"a" => "x", "b" => " "}, %{"a" => "x", "b" => "z"})

    assert part["missing"] == true
  end

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

  describe "compared/2: what each rule compares" do
    @standardized [
      %{
        "name" => "name_fuzzy",
        "kind" => "fuzzy",
        "field" => "name",
        "standardize" => ["unaccent", "legal_suffix"]
      },
      %{"name" => "lei_exact", "kind" => "exact", "fields" => ["lei"], "standardize" => ["lei"]},
      %{"name" => "mystery", "kind" => "telepathy", "field" => "name"}
    ]

    test "one entry per rule and field, with raw, compared and the standardizers" do
      assert [name, lei] =
               Match.compared(@standardized, %{
                 "name" => "  Société Acme Ltd. ",
                 "lei" => "5493001kjtiigc8y1r12"
               })

      assert %{
               "rule" => "name_fuzzy",
               "field" => "name",
               "raw" => "  Société Acme Ltd. ",
               "compared" => "societe acme",
               "standardize" => ["unaccent", "legal_suffix"],
               "absent" => false
             } = name

      assert %{"rule" => "lei_exact", "compared" => "5493001KJTIIGC8Y1R12", "absent" => false} =
               lei
    end

    test "a value a standardizer empties, or an invalid LEI, is absent" do
      assert [_name, %{"compared" => nil, "absent" => true}] =
               Match.compared(@standardized, %{"name" => "Acme", "lei" => "not-an-lei"})

      assert [%{"compared" => nil, "absent" => true}, %{"raw" => nil, "absent" => true}] =
               Match.compared(@standardized, %{"name" => "   "})
    end

    test "the compared values are what score/3 judges" do
      staged = %{"name" => "ACME Ltd", "lei" => nil}
      golden = %{"name" => "acme", "lei" => "5493001KJTIIGC8Y1R12"}
      rules = Enum.take(@standardized, 2)

      [s_name, s_lei] = Match.compared(rules, staged)
      [g_name, _g_lei] = Match.compared(rules, golden)

      {_score, parts} = Match.score(rules, staged, golden)

      assert s_name["compared"] == g_name["compared"]
      assert Decimal.eq?(parts["name_fuzzy"]["c"], 1)
      assert s_lei["absent"]
      assert parts["lei_exact"]["missing"]
    end
  end
end
