# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.ResolutionTest do
  @moduledoc "The pure planner: no database."

  use ExUnit.Case, async: true

  alias AshMdm.Resolution

  defp gap(attribute, material \\ false), do: %{attribute: attribute, material: material}

  defp resolver(name, kind, produces, opts \\ []) do
    %{
      name: name,
      kind: kind,
      produces: produces,
      requires: Keyword.get(opts, :requires, []),
      cost_rank: Keyword.get(opts, :cost, 10)
    }
  end

  defp by_attribute(plan), do: Map.new(plan, &{&1.attribute, &1})

  test "the closed vocabulary of kinds" do
    assert Resolution.kinds() == ~w(human inference judgment evidence enrichment)
  end

  describe "selection" do
    test "the lowest cost rank wins" do
      resolvers = [
        resolver("dear", "enrichment", ["tax_id"], cost: 50),
        resolver("cheap", "inference", ["tax_id"], cost: 5)
      ]

      assert [%{status: :planned, resolver: "cheap", round: 1, after: []}] =
               Resolution.plan([gap("tax_id")], resolvers, [])
    end

    test "a tie in cost goes to the lower name" do
      resolvers = [
        resolver("b", "inference", ["tax_id"]),
        resolver("a", "enrichment", ["tax_id"])
      ]

      assert [%{resolver: "a"}] = Resolution.plan([gap("tax_id")], resolvers, [])
    end

    test "an unusable cheap resolver does not block a dearer usable one" do
      resolvers = [
        resolver("cheap", "inference", ["tax_id"], cost: 1, requires: ["website"]),
        resolver("dear", "enrichment", ["tax_id"], cost: 9)
      ]

      assert [%{resolver: "dear"}] = Resolution.plan([gap("tax_id")], resolvers, [])
    end

    test "held attributes make a resolver usable" do
      resolvers = [resolver("lookup", "enrichment", ["tax_id"], requires: ["website"])]

      assert [%{status: :planned, resolver: "lookup", after: []}] =
               Resolution.plan([gap("tax_id")], resolvers, ["website"])

      assert [%{status: :planned}] =
               Resolution.plan([gap("tax_id")], resolvers, MapSet.new(["website"]))
    end

    test "one resolver can serve several gaps" do
      resolvers = [resolver("registry", "enrichment", ["tax_id", "legal_name"])]
      plan = Resolution.plan([gap("tax_id"), gap("legal_name")], resolvers, [])
      assert Enum.map(plan, & &1.resolver) == ["registry", "registry"]
    end
  end

  describe "chains" do
    test "a requirement produced by an earlier step makes a resolver usable" do
      resolvers = [
        resolver("find_site", "inference", ["website"]),
        resolver("read_site", "evidence", ["tax_id"], requires: ["website"])
      ]

      plan = by_attribute(Resolution.plan([gap("tax_id"), gap("website")], resolvers, []))

      assert %{resolver: "find_site", round: 1, after: []} = plan["website"]
      assert %{resolver: "read_site", round: 2, after: ["website"]} = plan["tax_id"]
    end

    test "a three step chain resolves in order" do
      resolvers = [
        resolver("a", "inference", ["x"]),
        resolver("b", "inference", ["y"], requires: ["x"]),
        resolver("c", "inference", ["z"], requires: ["y"])
      ]

      plan = by_attribute(Resolution.plan([gap("z"), gap("y"), gap("x")], resolvers, []))
      assert {plan["x"].round, plan["y"].round, plan["z"].round} == {1, 2, 3}
    end

    test "a step that produces more than its gap feeds later steps" do
      resolvers = [
        resolver("registry", "enrichment", ["legal_name", "website"]),
        resolver("read_site", "evidence", ["tax_id"], requires: ["website"])
      ]

      plan = by_attribute(Resolution.plan([gap("tax_id"), gap("legal_name")], resolvers, []))
      assert %{status: :planned, round: 2} = plan["tax_id"]
    end

    test "a requirement nothing produces is needs_input, naming it" do
      resolvers = [resolver("read_site", "evidence", ["tax_id"], requires: ["website"])]

      assert [%{status: :needs_input, resolver: "read_site", missing: ["website"]}] =
               Resolution.plan([gap("tax_id")], resolvers, [])
    end

    test "needs_input names the resolver with the least missing" do
      resolvers = [
        resolver("far", "inference", ["tax_id"], cost: 1, requires: ["a", "b"]),
        resolver("near", "inference", ["tax_id"], cost: 9, requires: ["c"])
      ]

      assert [%{resolver: "near", missing: ["c"]}] =
               Resolution.plan([gap("tax_id")], resolvers, [])
    end
  end

  describe "cycles" do
    test "a requires cycle ends in needs_input and terminates" do
      resolvers = [
        resolver("a", "inference", ["x"], requires: ["y"]),
        resolver("b", "inference", ["y"], requires: ["x"])
      ]

      plan = by_attribute(Resolution.plan([gap("x"), gap("y")], resolvers, []))
      assert %{status: :needs_input, missing: ["y"]} = plan["x"]
      assert %{status: :needs_input, missing: ["x"]} = plan["y"]
    end

    test "a cycle does not stop the rest of the plan" do
      resolvers = [
        resolver("a", "inference", ["x"], requires: ["y"]),
        resolver("b", "inference", ["y"], requires: ["x"]),
        resolver("c", "enrichment", ["z"])
      ]

      plan = by_attribute(Resolution.plan([gap("x"), gap("y"), gap("z")], resolvers, []))
      assert plan["z"].status == :planned
      assert plan["x"].status == :needs_input
    end

    test "an escape from the cycle lets it resolve" do
      resolvers = [
        resolver("a", "inference", ["x"], requires: ["y"]),
        resolver("b", "inference", ["y"], requires: ["x"])
      ]

      plan = by_attribute(Resolution.plan([gap("x"), gap("y")], resolvers, ["x"]))
      assert %{status: :planned, resolver: "b"} = plan["y"]
      assert %{status: :planned, resolver: "a", round: 2} = plan["x"]
    end
  end

  describe "no route" do
    test "nothing produces the attribute" do
      resolvers = [resolver("lookup", "enrichment", ["website"])]

      assert [%{attribute: "tax_id", status: :no_route, because: because}] =
               Resolution.plan([gap("tax_id")], resolvers, [])

      assert is_binary(because) and because != ""
    end

    test "no resolvers at all" do
      assert [%{status: :no_route}] = Resolution.plan([gap("tax_id")], [], [])
    end

    test "no gaps, no plan" do
      assert Resolution.plan([], [resolver("a", "human", ["x"])], []) == []
    end
  end

  describe "material gaps" do
    test "a non-human step on a material gap needs a person to admit it" do
      resolvers = [resolver("lookup", "enrichment", ["tax_id"])]

      assert [%{status: :planned, needs_person: true}] =
               Resolution.plan([gap("tax_id", true)], resolvers, [])
    end

    test "every non-human kind needs a person" do
      for kind <- Resolution.kinds() -- ["human"] do
        resolvers = [resolver("r", kind, ["tax_id"])]
        assert [%{needs_person: true}] = Resolution.plan([gap("tax_id", true)], resolvers, [])
      end
    end

    test "a human step is the person already" do
      resolvers = [resolver("ask", "human", ["tax_id"])]
      assert [%{needs_person: false}] = Resolution.plan([gap("tax_id", true)], resolvers, [])
    end

    test "a gap that is not material needs no admission" do
      resolvers = [resolver("lookup", "enrichment", ["tax_id"])]
      assert [%{needs_person: false}] = Resolution.plan([gap("tax_id")], resolvers, [])
    end

    test "the choice is not changed by materiality: cheapest wins, then is flagged" do
      resolvers = [
        resolver("ask", "human", ["tax_id"], cost: 90),
        resolver("lookup", "enrichment", ["tax_id"], cost: 1)
      ]

      assert [%{resolver: "lookup", needs_person: true}] =
               Resolution.plan([gap("tax_id", true)], resolvers, [])
    end

    test "material is read from real completeness gaps" do
      requirements = [
        %{"attribute" => "tax_id", "need" => "required", "because" => "r", "material" => true},
        %{"attribute" => "website", "need" => "required", "because" => "r"}
      ]

      resolvers = [
        resolver("lookup", "enrichment", ["tax_id"]),
        resolver("find", "inference", ["website"])
      ]

      plan =
        requirements
        |> AshMdm.Completeness.gaps([])
        |> Resolution.plan(resolvers, [])
        |> by_attribute()

      assert plan["tax_id"].needs_person
      refute plan["website"].needs_person
    end
  end

  describe "accepted origins" do
    defp picky(attribute, accepted, material \\ false),
      do: %{attribute: attribute, material: material, accepted_origins: accepted}

    test "a cheaper resolver of an origin the purpose refuses is passed over" do
      resolvers = [
        resolver("scrape", "inference", ["tax_id"], cost: 1),
        resolver("registry", "enrichment", ["tax_id"], cost: 9)
      ]

      assert [%{status: :planned, resolver: "registry", needs_person: false}] =
               Resolution.plan([picky("tax_id", ["enrichment"])], resolvers, [])
    end

    test "when only refused origins produce it there is no route, and it says why" do
      resolvers = [resolver("scrape", "inference", ["tax_id"])]

      assert [%{status: :no_route, because: because}] =
               Resolution.plan([picky("tax_id", ["human"])], resolvers, [])

      assert because =~ "accept"
    end

    test "needs_input never names a resolver the purpose would refuse" do
      resolvers = [
        resolver("scrape", "inference", ["tax_id"], requires: ["a"]),
        resolver("registry", "enrichment", ["tax_id"], requires: ["b", "c"])
      ]

      assert [%{status: :needs_input, resolver: "registry", missing: ["b", "c"]}] =
               Resolution.plan([picky("tax_id", ["enrichment"])], resolvers, [])
    end

    test "a refused step feeds nothing, because it is never planned" do
      resolvers = [
        resolver("scrape", "inference", ["website"]),
        resolver("read", "evidence", ["tax_id"], requires: ["website"])
      ]

      plan =
        by_attribute(Resolution.plan([picky("website", ["human"]), gap("tax_id")], resolvers, []))

      assert plan["website"].status == :no_route
      assert %{status: :needs_input, missing: ["website"]} = plan["tax_id"]
    end

    test "a material gap closes on the person's statement, whatever produced the draft" do
      resolvers = [resolver("lookup", "enrichment", ["tax_id"])]

      assert [%{status: :planned, resolver: "lookup", needs_person: true}] =
               Resolution.plan([picky("tax_id", ["human"], true)], resolvers, [])
    end

    test "a material gap that refuses people's statements cannot be closed" do
      resolvers = [
        resolver("lookup", "enrichment", ["tax_id"]),
        resolver("ask", "human", ["tax_id"])
      ]

      assert [%{status: :no_route}] =
               Resolution.plan([picky("tax_id", ["enrichment"], true)], resolvers, [])
    end

    test "a gap repeated across purposes must satisfy every one of them" do
      resolvers = [
        resolver("scrape", "inference", ["tax_id"], cost: 1),
        resolver("registry", "enrichment", ["tax_id"], cost: 5),
        resolver("ask", "human", ["tax_id"], cost: 9)
      ]

      gaps = [
        picky("tax_id", ["inference", "enrichment"]),
        picky("tax_id", ["enrichment", "human"])
      ]

      assert [%{resolver: "registry"}] = Resolution.plan(gaps, resolvers, [])
      assert [%{resolver: "registry"}] = Resolution.plan(Enum.reverse(gaps), resolvers, [])
    end

    test "a gap with no opinion on origin does not narrow one that has" do
      resolvers = [
        resolver("scrape", "inference", ["tax_id"], cost: 1),
        resolver("registry", "enrichment", ["tax_id"], cost: 5)
      ]

      assert [%{resolver: "registry"}] =
               Resolution.plan([gap("tax_id"), picky("tax_id", ["enrichment"])], resolvers, [])
    end

    test "read from real completeness gaps" do
      requirements = [
        %{
          "attribute" => "tax_id",
          "need" => "required",
          "because" => "r",
          "accepted_origins" => ["enrichment"]
        }
      ]

      assertion = %{
        id: 1,
        attribute: "tax_id",
        value: AshMdm.Assertions.wrap_value("123"),
        origin_kind: :inference,
        source: "site",
        band: :admit,
        observed_at: ~U[2026-01-01 00:00:00Z]
      }

      resolvers = [
        resolver("scrape", "inference", ["tax_id"], cost: 1),
        resolver("registry", "enrichment", ["tax_id"], cost: 5)
      ]

      assert [%{kind: :origin_not_accepted} = found] =
               AshMdm.Completeness.gaps(requirements, [assertion])

      assert [%{resolver: "registry"}] = Resolution.plan([found], resolvers, [])
    end
  end

  describe "input order" do
    test "gaps, resolvers and held in any order give one answer" do
      gaps = [gap("a"), gap("b", true), gap("c"), gap("d"), gap("e")]

      resolvers = [
        resolver("r1", "inference", ["a"], cost: 3),
        resolver("r2", "enrichment", ["a", "b"], cost: 3),
        resolver("r3", "evidence", ["c"], requires: ["a"], cost: 2),
        resolver("r4", "human", ["d"], requires: ["e"]),
        resolver("r5", "human", ["e"], requires: ["d"]),
        resolver("r6", "judgment", ["c"], requires: ["h"], cost: 1)
      ]

      expected = Resolution.plan(gaps, resolvers, ["h", "i"])

      for seed <- 1..25 do
        :rand.seed(:exsss, {seed, seed, seed})

        assert expected ==
                 Resolution.plan(
                   Enum.shuffle(gaps),
                   Enum.shuffle(resolvers),
                   Enum.shuffle(["h", "i"])
                 )
      end
    end

    test "the answer is sorted by attribute" do
      plan = Resolution.plan([gap("z"), gap("a"), gap("m")], [], [])
      assert Enum.map(plan, & &1.attribute) == ["a", "m", "z"]
    end

    test "a repeated gap is planned once" do
      resolvers = [resolver("lookup", "enrichment", ["tax_id"])]

      assert [%{needs_person: true}] =
               Resolution.plan([gap("tax_id"), gap("tax_id", true)], resolvers, [])
    end
  end
end
