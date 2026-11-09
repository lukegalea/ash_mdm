# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.StandardizeTest do
  @moduledoc "The closed standardizers and how a rule uses them."

  use ExUnit.Case, async: true

  alias AshMdm.Match
  alias AshMdm.Standardize

  @lei "5493001KJTIIGC8Y1R12"

  describe "unaccent" do
    test "removes combining marks" do
      assert Standardize.run("société générale", ["unaccent"]) == "societe generale"
    end

    test "leaves plain text alone" do
      assert Standardize.run("acme", ["unaccent"]) == "acme"
    end

    for {label, input} <- [
          {"Devanagari", "हिन्दी कोश"},
          {"Thai", "ก็ไม่เป็นไร"},
          {"Japanese", "がぎ パイ"}
        ] do
      test "keeps the marks that distinguish #{label} words" do
        input = unquote(input)
        assert Standardize.run(input, ["unaccent"]) == String.normalize(input, :nfc)
      end
    end

    test "leaves a precomposed non-Latin letter as it found it" do
      assert Standardize.run("が", ["unaccent"]) == "が"
    end

    test "removes every mark stacked on a Latin letter" do
      assert Standardize.run("a\u0301\u0323", ["unaccent"]) == "a"
    end

    test "removes a mark on a Latin letter beside non-Latin text" do
      assert Standardize.run("société कोश", ["unaccent"]) == "societe कोश"
    end
  end

  describe "legal_suffix" do
    for {input, expected} <- [
          {"acme, inc.", "acme"},
          {"acme inc", "acme"},
          {"acme l.l.c.", "acme"},
          {"acme limited liability company", "acme"},
          {"acme holdings ltd", "acme holdings"},
          {"acme & co", "acme"},
          {"acme co. ltd.", "acme"},
          {"acme gmbh", "acme"}
        ] do
      test "#{input}" do
        assert Standardize.run(unquote(input), ["legal_suffix"]) == unquote(expected)
      end
    end

    test "leaves a legal word that isn't at the end" do
      assert Standardize.run("limited brands of ohio", ["legal_suffix"]) ==
               "limited brands of ohio"
    end

    for {input, expected} <- [
          {"eni s.p.a.", "eni"},
          {"eni, s.p.a.", "eni"},
          {"eni s.p.a", "eni"},
          {"eni s.p.a.,", "eni"},
          {"eni s.p.a., inc.", "eni"},
          {"s.p.a.", "s.p.a."},
          {"s.p.a. foods", "spa foods"}
        ] do
      test "the dotted Italian form: #{input}" do
        assert Standardize.run(unquote(input), ["legal_suffix"]) == unquote(expected)
      end
    end

    test "spa is a word, not a legal form" do
      assert Standardize.run("hillside spa", ["legal_suffix"]) == "hillside spa"
    end

    for {label, space} <- [
          {"a non-breaking space", "\u00A0"},
          {"a narrow non-breaking space", "\u202F"},
          {"an ideographic space", "\u3000"},
          {"a tab", "\t"}
        ] do
      test "splits on #{label}" do
        assert Standardize.run("acme#{unquote(space)}inc", ["legal_suffix"]) == "acme"
      end
    end

    test "a name that is only a legal form stays" do
      assert Standardize.run("limited", ["legal_suffix"]) == "limited"
    end
  end

  describe "lei" do
    test "keeps a valid identifier, upcased" do
      assert Standardize.run(String.downcase(@lei), ["lei"]) == @lei
    end

    test "a wrong check digit is absent" do
      assert Standardize.run("5493001KJTIIGC8Y1R13", ["lei"]) == nil
    end

    test "a wrong length is absent" do
      assert Standardize.run("5493001KJT", ["lei"]) == nil
    end

    test "punctuation is absent" do
      assert Standardize.run("5493001KJTIIGC8Y1R-2", ["lei"]) == nil
    end
  end

  describe "run/2" do
    test "applies in the order listed" do
      assert Standardize.run("société sàrl", ["unaccent", "legal_suffix"]) == "societe"
    end

    test "nil stays nil and stops the chain" do
      assert Standardize.run(nil, ["unaccent"]) == nil
      assert Standardize.run("bad", ["lei", "unaccent"]) == nil
    end
  end

  describe "in a rule" do
    @name %{"name" => "n", "kind" => "fuzzy", "field" => "name"}
    @lei_rule %{"name" => "l", "kind" => "exact", "fields" => ["lei"], "standardize" => ["lei"]}

    test "a legal-suffix pair scores 1" do
      rule = Map.put(@name, "standardize", ["legal_suffix"])
      assert {score, _} = Match.score([rule], %{"name" => "Acme, Inc."}, %{"name" => "ACME Ltd"})
      assert Decimal.eq?(score, 1)
    end

    @exact_name %{"name" => "e", "kind" => "exact", "fields" => ["name"]}

    test "two blank values are missing, not an agreement" do
      assert {score, %{"e" => %{"missing" => true}}} =
               Match.score([@exact_name], %{"name" => "   "}, %{"name" => ""})

      assert Decimal.eq?(score, 0)
    end

    test "a blank value on a fuzzy rule is missing" do
      assert {_, %{"n" => %{"missing" => true}}} =
               Match.score([@name], %{"name" => "  "}, %{"name" => "Acme"})
    end

    test "a value of only Unicode whitespace is missing" do
      assert {_, %{"e" => %{"missing" => true}}} =
               Match.score([@exact_name], %{"name" => "\u00A0\u3000"}, %{"name" => "\u00A0"})
    end

    test "a rule with no standardize scores as before" do
      {score, _} = Match.score([@name], %{"name" => "Acme, Inc."}, %{"name" => "ACME Ltd"})
      assert Decimal.lt?(score, 1)
    end

    test "an invalid identifier on either side is missing, not a disagreement" do
      assert {_, %{"l" => %{"missing" => true}}} =
               Match.score([@lei_rule], %{"lei" => "nope"}, %{"lei" => @lei})
    end

    test "two equal invalid identifiers do not match" do
      assert {score, _} = Match.score([@lei_rule], %{"lei" => "nope"}, %{"lei" => "nope"})
      assert Decimal.eq?(score, 0)
    end
  end

  describe "the missing flag" do
    @exact %{"name" => "e", "kind" => "exact", "fields" => ["email"]}
    @fuzzy %{"name" => "f", "kind" => "fuzzy", "field" => "name"}

    test "marks an exact rule with no value" do
      assert {_, %{"e" => %{"missing" => true}}} = Match.score([@exact], %{}, %{"email" => "a"})
    end

    test "marks a fuzzy rule with no value" do
      assert {_, %{"f" => %{"missing" => true}}} = Match.score([@fuzzy], %{"name" => "a"}, %{})
    end

    test "is absent from a real disagreement" do
      {_, %{"e" => entry}} = Match.score([@exact], %{"email" => "a"}, %{"email" => "b"})
      refute Map.has_key?(entry, "missing")
    end

    test "a missing rule still counts its weight" do
      {score, _} =
        Match.score([@exact, @fuzzy], %{"email" => "a", "name" => "x"}, %{"email" => "a"})

      assert Decimal.eq?(score, Decimal.new("0.5"))
    end
  end
end
