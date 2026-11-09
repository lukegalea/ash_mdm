# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.MatchRuleActivationTest do
  @moduledoc "Activation refuses rules that would score wrongly without complaint."

  use ExUnit.Case, async: false

  alias AshMdm.Fixtures.MatchRuleSet

  @moduletag :db

  @exact %{"name" => "e", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}
  @fuzzy %{"name" => "f", "kind" => "fuzzy", "field" => "name", "algorithm" => "jaro"}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp activate(rules) do
    MatchRuleSet
    |> Ash.Changeset.for_create(:draft, %{
      golden_resource: "golden-#{System.unique_integer([:positive])}",
      rules: rules,
      survivorship: %{}
    })
    |> Ash.create!(authorize?: false)
    |> Ash.Changeset.for_update(:activate)
    |> Ash.update(authorize?: false)
  end

  test "accepts well-formed rules, weight optional" do
    assert {:ok, %{status: :active}} = activate([@exact, @fuzzy])
  end

  test "accepts known standardizers" do
    rule = Map.put(@fuzzy, "standardize", ["unaccent", "legal_suffix"])
    assert {:ok, %{status: :active}} = activate([rule])
  end

  for {label, rule} <- [
        {"an unknown kind", %{"name" => "x", "kind" => "soundex", "field" => "name"}},
        {"no name", %{"kind" => "exact", "fields" => ["email"]}},
        {"exact with no fields", %{"name" => "x", "kind" => "exact", "fields" => []}},
        {"fuzzy with no field", %{"name" => "x", "kind" => "fuzzy"}},
        {"an unknown algorithm",
         %{"name" => "x", "kind" => "fuzzy", "field" => "n", "algorithm" => "soundex"}},
        {"a zero weight", %{"name" => "x", "kind" => "fuzzy", "field" => "n", "weight" => 0}},
        {"a text weight", %{"name" => "x", "kind" => "fuzzy", "field" => "n", "weight" => "1"}},
        {"an unknown standardizer",
         %{"name" => "x", "kind" => "fuzzy", "field" => "n", "standardize" => ["phonetic"]}},
        {"standardize not a list",
         %{"name" => "x", "kind" => "fuzzy", "field" => "n", "standardize" => "lei"}}
      ] do
    test "refuses #{label}" do
      assert {:error, _} = activate([unquote(Macro.escape(rule))])
    end
  end

  test "refuses two rules with one name" do
    assert {:error, _} = activate([@exact, %{@fuzzy | "name" => "e"}])
  end
end
