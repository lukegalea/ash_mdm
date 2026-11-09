# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.RuleSetContentHashTest do
  @moduledoc """
  A match rule set's `content_hash` is the identity of what it decides:
  its `rules` and its `survivorship`, and nothing else.
  """

  use ExUnit.Case, async: false

  @moduletag :db

  alias AshMdm.Fixtures.{Mapping, MatchRuleSet}
  alias AshMdm.Mapping.ContentHash

  @rules [%{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}]
  @survivorship %{"default" => "non_null"}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp draft!(attrs) do
    MatchRuleSet
    |> Ash.Changeset.for_create(
      :draft,
      Map.merge(
        %{golden_resource: "AshMdm.Fixtures.Person", rules: @rules, survivorship: @survivorship},
        Map.new(attrs)
      ),
      authorize?: false
    )
    |> Ash.create!()
  end

  test "the hash covers the rules and the survivorship" do
    assert draft!([]).content_hash ==
             ContentHash.hash!(%{rules: @rules, survivorship: @survivorship})
  end

  test "rule sets that differ in their rules hash differently" do
    other = [
      %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 2.0}
    ]

    refute draft!([]).content_hash == draft!(rules: other).content_hash
  end

  test "rule sets that differ in their survivorship hash differently" do
    refute draft!([]).content_hash ==
             draft!(survivorship: %{"default" => "most_recent"}).content_hash
  end

  test "key order alone does not change the hash" do
    one =
      draft!(
        rules: Jason.decode!(~s([{"kind":"exact","name":"e","fields":["email"],"weight":1.0}])),
        survivorship:
          Jason.decode!(~s({"default":"non_null","attributes":{"a":{"strategy":"non_null"}}}))
      )

    two =
      draft!(
        rules: Jason.decode!(~s([{"weight":1.0,"fields":["email"],"name":"e","kind":"exact"}])),
        survivorship:
          Jason.decode!(~s({"attributes":{"a":{"strategy":"non_null"}},"default":"non_null"}))
      )

    assert one.content_hash == two.content_hash
  end

  test "a rule set with no survivorship still hashes its rules" do
    refute draft!(survivorship: nil).content_hash ==
             draft!(survivorship: nil, rules: [%{"name" => "other"}]).content_hash
  end

  describe "ContentHash" do
    test "key order does not matter in a map too large to iterate sorted" do
      pairs = for n <- 1..100, do: {"key_#{n}", n}

      assert ContentHash.hash!(Map.new(pairs)) == ContentHash.hash!(Map.new(Enum.reverse(pairs)))
    end

    test "atom and string keys hash alike" do
      assert ContentHash.hash!(%{rules: [%{kind: "exact"}]}) ==
               ContentHash.hash!(%{"rules" => [%{"kind" => "exact"}]})
    end

    test "a struct value hashes by its JSON instead of raising" do
      assert ContentHash.hash!(%{"weight" => Decimal.new("0.5")}) ==
               ContentHash.hash!(%{"weight" => "0.5"})
    end
  end

  test "a field the resource does not have raises instead of hashing nothing" do
    assert_raise ArgumentError, ~r/no attribute :field_rules/, fn ->
      MatchRuleSet
      |> Ash.Changeset.new()
      |> AshMdm.Changes.SetContentHash.change([fields: [:field_rules]], %{})
    end
  end

  test "every create action stamps the hash from fields the resource has" do
    for resource <- [Mapping, MatchRuleSet],
        action <- Ash.Resource.Info.actions(resource),
        action.type == :create do
      assert [%{change: {AshMdm.Changes.SetContentHash, opts}}] =
               Enum.filter(
                 action.changes,
                 &match?(%{change: {AshMdm.Changes.SetContentHash, _}}, &1)
               ),
             "#{inspect(resource)}.#{action.name} does not stamp content_hash"

      for field <- opts[:fields] do
        assert Ash.Resource.Info.attribute(resource, field)
      end
    end
  end
end
