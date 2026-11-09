# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.TuningTest do
  @moduledoc "Proposing rule weights from judged pairs."

  use ExUnit.Case, async: false

  alias AshMdm.Fixtures.MatchRuleSet
  alias AshMdm.Tuning

  @email %{"name" => "email", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}
  @name %{"name" => "name", "kind" => "fuzzy", "field" => "name", "weight" => 1.0}

  defp pair(verdict, contributions) do
    %{
      verdict: verdict,
      explanation:
        Map.new(contributions, fn
          {name, :missing} -> {name, %{"w" => 1, "c" => Decimal.new(0), "missing" => true}}
          {name, c} -> {name, %{"w" => 1, "c" => c}}
        end)
    }
  end

  defp pairs(n, verdict, contributions), do: List.duplicate(pair(verdict, contributions), n)

  defp report_for(result, name), do: Enum.find(result.report, &(&1.rule == name))
  defp weight_of(result, name), do: Enum.find(result.rules, &(&1["name"] == name))["weight"]

  @one Decimal.new(1)
  @zero Decimal.new(0)

  defp balanced(rule_name, agree_on_match, agree_on_non_match) do
    pairs(agree_on_match, :match, [{rule_name, @one}]) ++
      pairs(20 - agree_on_match, :match, [{rule_name, @zero}]) ++
      pairs(agree_on_non_match, :non_match, [{rule_name, @one}]) ++
      pairs(20 - agree_on_non_match, :non_match, [{rule_name, @zero}])
  end

  test "a rule that separates matches earns more than one that doesn't" do
    labelled = balanced("email", 19, 1) ++ balanced("name", 15, 8)
    result = Tuning.propose([@email, @name], labelled)

    assert weight_of(result, "email") > weight_of(result, "name")
    assert report_for(result, "email").status == :proposed
  end

  test "the weight is log2 of the smoothed rates" do
    result = Tuning.propose([@email], balanced("email", 18, 2))

    assert report_for(result, "email").m == Float.round(18.5 / 21, 4)
    assert report_for(result, "email").u == Float.round(2.5 / 21, 4)
    assert weight_of(result, "email") == Float.round(:math.log2(18.5 / 2.5), 4)
  end

  test "a rule that never disagrees still gets a finite weight" do
    assert is_float(weight_of(Tuning.propose([@email], balanced("email", 20, 0)), "email"))
  end

  test "agreement on non-matches floors the weight and says so" do
    result = Tuning.propose([@email], balanced("email", 5, 15))

    assert weight_of(result, "email") == 0.01
    assert report_for(result, "email").status == :floored
  end

  test "a rule agreeing equally on both is floored" do
    assert report_for(Tuning.propose([@email], balanced("email", 10, 10)), "email").status ==
             :floored
  end

  test "a strong fuzzy contribution counts as agreement, a weak one doesn't" do
    strong = pairs(20, :match, [{"name", Decimal.new("0.9")}])
    weak = pairs(20, :non_match, [{"name", Decimal.new("0.8")}])

    result = Tuning.propose([@name], strong ++ weak)

    assert report_for(result, "name").m == Float.round(20.5 / 21, 4)
    assert report_for(result, "name").u == Float.round(0.5 / 21, 4)
  end

  test "exactly the threshold agrees" do
    labelled =
      pairs(10, :match, [{"name", Decimal.new("0.85")}]) ++
        pairs(10, :non_match, [{"name", @zero}])

    assert report_for(Tuning.propose([@name], labelled), "name").m == Float.round(10.5 / 11, 4)
  end

  test "a missing value says nothing about the pair" do
    labelled = balanced("email", 18, 2) ++ pairs(50, :match, [{"email", :missing}])
    result = Tuning.propose([@email], labelled)

    assert report_for(result, "email").matches == 20
    assert weight_of(result, "email") == Float.round(:math.log2(18.5 / 2.5), 4)
  end

  test "too few labels of either kind keeps the rule untouched" do
    labelled = pairs(9, :match, [{"email", @one}]) ++ pairs(30, :non_match, [{"email", @zero}])
    result = Tuning.propose([@email], labelled)

    assert result.rules == [@email]
    assert report_for(result, "email").status == :insufficient_labels
    assert report_for(result, "email").weight_after == 1.0
  end

  test "ten of each is enough" do
    labelled = pairs(10, :match, [{"email", @one}]) ++ pairs(10, :non_match, [{"email", @zero}])
    assert report_for(Tuning.propose([@email], labelled), "email").status == :proposed
  end

  describe "a rule set partly tuned" do
    @kept %{"name" => "kept", "kind" => "exact", "fields" => ["x"], "weight" => 2.0}

    test "the tuned rules keep the combined share they had" do
      labelled = balanced("email", 18, 2) ++ balanced("name", 16, 4)
      result = Tuning.propose([@email, @name, @kept], labelled)

      assert weight_of(result, "kept") == 2.0
      assert_in_delta weight_of(result, "email") + weight_of(result, "name"), 2.0, 0.001
      assert report_for(result, "email").status == :proposed
      assert report_for(result, "kept").status == :insufficient_labels
    end

    test "the proportion between tuned rules survives" do
      labelled = balanced("email", 18, 2) ++ balanced("name", 16, 4)
      alone = Tuning.propose([@email, @name], labelled)
      partial = Tuning.propose([@email, @name, @kept], labelled)

      assert_in_delta weight_of(partial, "email") / weight_of(partial, "name"),
                      weight_of(alone, "email") / weight_of(alone, "name"),
                      0.01
    end

    test "a prior with no weight counts as 1.0" do
      labelled = balanced("email", 18, 2)
      rule = Map.delete(@email, "weight")
      result = Tuning.propose([rule, @kept], labelled)

      assert_in_delta weight_of(result, "email"), 1.0, 0.001
    end

    test "the floor applies after the rescale" do
      strong = %{"name" => "strong", "kind" => "exact", "fields" => ["a"], "weight" => 0.5}
      weak = %{"name" => "weak", "kind" => "exact", "fields" => ["b"], "weight" => 0.5}
      labelled = balanced("strong", 20, 0) ++ balanced("weak", 5, 15)

      result = Tuning.propose([strong, weak, @kept], labelled)

      assert weight_of(result, "weak") == 0.01
      assert report_for(result, "weak").status == :floored
    end

    test "a report entry says it was rescaled, and by how much" do
      labelled = balanced("email", 18, 2)
      result = Tuning.propose([@email, @kept], labelled)
      entry = report_for(result, "email")

      assert entry.rescaled == true
      assert_in_delta entry.scale, 1.0 / Float.round(:math.log2(18.5 / 2.5), 4), 0.0001
      assert report_for(result, "kept").rescaled == false
      assert report_for(result, "kept").scale == nil
    end

    test "with every rule tuned nothing is rescaled" do
      labelled = balanced("email", 18, 2) ++ balanced("name", 16, 4)
      result = Tuning.propose([@email, @name], labelled)

      assert weight_of(result, "email") == Float.round(:math.log2(18.5 / 2.5), 4)
      assert report_for(result, "email").rescaled == false
      assert report_for(result, "email").scale == nil
    end

    test "with no rule tuned nothing changes" do
      assert Tuning.propose([@email, @kept], []).rules == [@email, @kept]
    end
  end

  test "a rule with no weight of its own stays without one when unlabelled" do
    rule = Map.delete(@email, "weight")
    assert %{rules: [^rule]} = Tuning.propose([rule], [])
  end

  test "verdicts other than match and non_match are ignored" do
    labelled = balanced("email", 18, 2) ++ pairs(40, :unsure, [{"email", @one}])
    assert report_for(Tuning.propose([@email], labelled), "email").matches == 20
  end

  test "contributions read back from JSON as strings" do
    labelled = pairs(10, :match, [{"email", "1"}]) ++ pairs(10, :non_match, [{"email", "0.0"}])
    assert report_for(Tuning.propose([@email], labelled), "email").status == :proposed
  end

  test "a pair scored before a rule existed doesn't count for it" do
    labelled = balanced("email", 18, 2) ++ pairs(30, :match, [{"other", @one}])
    assert report_for(Tuning.propose([@email], labelled), "email").matches == 20
  end

  test "input order doesn't change the proposal" do
    labelled = balanced("email", 18, 2) ++ balanced("name", 15, 8)

    assert Tuning.propose([@email, @name], labelled) ==
             Tuning.propose([@email, @name], Enum.shuffle(labelled))
  end

  test "keeps rule order and every other key" do
    rule = Map.put(@name, "algorithm", "jaro")
    result = Tuning.propose([rule, @email], balanced("name", 15, 2) ++ balanced("email", 18, 2))

    assert [%{"name" => "name", "algorithm" => "jaro"}, %{"name" => "email"}] = result.rules
  end

  describe "a proposal as a new version" do
    @describetag :db

    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
      :ok
    end

    defp active_set! do
      MatchRuleSet
      |> Ash.Changeset.for_create(:draft, %{
        golden_resource: "golden-#{System.unique_integer([:positive])}",
        rules: [@email],
        survivorship: %{}
      })
      |> Ash.create!(authorize?: false)
      |> Ash.Changeset.for_update(:activate)
      |> Ash.update!(authorize?: false)
    end

    defp version_of(rule_set, rules) do
      MatchRuleSet
      |> Ash.Changeset.for_create(:create_version, %{
        from_rule_set_id: rule_set.id,
        rules: rules,
        survivorship: rule_set.survivorship
      })
      |> Ash.create!(authorize?: false)
    end

    test "is a draft on the same chain with a new hash, and the current set stays active" do
      current = active_set!()
      %{rules: proposed} = Tuning.propose([@email], balanced("email", 18, 2))

      draft = version_of(current, proposed)

      assert draft.status == :draft
      assert draft.version == 2
      assert draft.root_id == current.id
      assert draft.golden_resource == current.golden_resource
      assert draft.content_hash != current.content_hash
      assert %{status: :active} = Ash.get!(MatchRuleSet, current.id, authorize?: false)
    end

    test "activating it retires the set it came from" do
      current = active_set!()
      %{rules: proposed} = Tuning.propose([@email], balanced("email", 5, 15))

      assert {:ok, %{status: :active}} =
               current
               |> version_of(proposed)
               |> Ash.Changeset.for_update(:activate)
               |> Ash.update(authorize?: false)

      assert %{status: :retired} = Ash.get!(MatchRuleSet, current.id, authorize?: false)
    end

    test "a version cannot move to another golden" do
      current = active_set!()

      assert_raise Ash.Error.Invalid, fn ->
        MatchRuleSet
        |> Ash.Changeset.for_create(:create_version, %{
          from_rule_set_id: current.id,
          golden_resource: "elsewhere",
          rules: [@email],
          survivorship: %{}
        })
        |> Ash.create!(authorize?: false)
      end
    end
  end
end
