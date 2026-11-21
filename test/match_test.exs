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

  describe "overlap rules" do
    defp overlap(measure, threshold),
      do: %{
        "name" => "o",
        "kind" => "overlap",
        "field" => "meetings",
        "measure" => measure,
        "threshold" => threshold
      }

    defp overlap_part(rule, a, b) do
      {_score, %{"o" => part}} = Match.score([rule], %{"meetings" => a}, %{"meetings" => b})
      part
    end

    test "count meets its threshold on shared items" do
      part = overlap_part(overlap("count", 2), ["m1", "m2", "m3"], ["m2", "m3", "m9"])

      assert Decimal.eq?(part["c"], 1)

      assert %{"shared" => 2, "union" => 4, "measure" => "count", "threshold" => 2} =
               part["detail"]
    end

    test "count below its threshold contributes 0 but is not missing" do
      part = overlap_part(overlap("count", 2), ["m1", "m2"], ["m2", "m9"])

      assert Decimal.eq?(part["c"], 0)
      refute Map.has_key?(part, "missing")
      assert part["detail"]["shared"] == 1
    end

    test "jaccard is shared over union" do
      met = overlap_part(overlap("jaccard", 0.5), ["a", "b", "c"], ["b", "c", "d"])
      assert Decimal.eq?(met["c"], 1)
      assert met["detail"]["value"] == 0.5

      unmet = overlap_part(overlap("jaccard", 0.6), ["a", "b", "c"], ["b", "c", "d"])
      assert Decimal.eq?(unmet["c"], 0)
    end

    test "items are normalised, blanks dropped and duplicates collapsed" do
      part = overlap_part(overlap("count", 2), [" A ", "a", "B", ""], ["a", "b"])
      assert Decimal.eq?(part["c"], 1)
      assert part["detail"]["union"] == 2
    end

    test "an empty or absent list on either side is missing, never a match" do
      for {a, b} <- [{[], ["x"]}, {["x"], nil}, {[" "], ["x"]}] do
        part = overlap_part(overlap("count", 1), a, b)
        assert part["missing"] == true
        assert Decimal.eq?(part["c"], 0)
      end
    end

    test "weight and score fold like any other rule" do
      rules = [Map.put(overlap("count", 1), "weight", 1.0), Enum.at(@rules, 0)]

      {score, _} =
        Match.score(rules, %{"meetings" => ["m"], "email" => "a@b.c"}, %{
          "meetings" => ["m"],
          "email" => "a@b.c"
        })

      assert Decimal.eq?(score, 1)
    end

    test "compared/2 reports the distinct sorted items" do
      assert [
               %{
                 "rule" => "o",
                 "field" => "meetings",
                 "compared" => ["a", "b"],
                 "absent" => false
               }
             ] =
               Match.compared([overlap("count", 1)], %{"meetings" => ["B", "a", "b"]})

      assert [%{"compared" => nil, "absent" => true}] =
               Match.compared([overlap("count", 1)], %{"meetings" => []})
    end
  end
end
