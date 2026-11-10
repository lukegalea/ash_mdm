# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.AssertionsTest do
  @moduledoc "The fold over attribute assertions."

  use ExUnit.Case, async: true

  alias AshMdm.Assertions
  alias AshMdm.Survivorship

  @early ~U[2026-01-01 00:00:00.000000Z]
  @late ~U[2026-06-01 00:00:00.000000Z]
  @golden "11111111-1111-1111-1111-111111111111"
  @absorbed "22222222-2222-2222-2222-222222222222"

  defp assertion(id, attribute, value, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        golden_id: @golden,
        attribute: attribute,
        value: Assertions.wrap_value(value),
        origin_kind: :import,
        origin_ref: %{"landing" => id},
        source: "crm",
        band: nil,
        observed_at: @early,
        retracts_id: nil
      },
      overrides
    )
  end

  describe "the default order" do
    test "the value already held beats one that arrives later" do
      assertions = [
        assertion("b", "name", "Later", %{observed_at: @late, source: "erp"}),
        assertion("a", "name", "Held")
      ]

      assert %{merged: %{"name" => "Held"}} = Assertions.fold(%{}, assertions)
    end

    test "input order does not matter" do
      one = assertion("a", "name", "Held")
      two = assertion("b", "name", "Later", %{observed_at: @late, source: "erp"})

      assert Assertions.fold(%{}, [one, two]) == Assertions.fold(%{}, [two, one])
    end

    test "the survivor beats an absorbed record, even an older one" do
      assertions = [
        assertion("a", "name", "Absorbed", %{golden_id: @absorbed}),
        assertion("b", "name", "Survivor", %{observed_at: @late})
      ]

      depths = Assertions.chain_depths(@golden, [{@absorbed, @golden}])

      assert %{merged: %{"name" => "Survivor"}} =
               Assertions.fold(%{}, assertions, depths: depths)
    end

    test "an absorbed record fills what the survivor lacks" do
      assertions = [
        assertion("a", "email", "a@x.io", %{golden_id: @absorbed}),
        assertion("b", "name", "Survivor")
      ]

      depths = Assertions.chain_depths(@golden, [{@absorbed, @golden}])

      assert %{merged: %{"name" => "Survivor", "email" => "a@x.io"}} =
               Assertions.fold(%{}, assertions, depths: depths)
    end
  end

  describe "a source speaks for itself once" do
    test "a correction replaces the same source's earlier statement" do
      assertions = [
        assertion("a", "name", "Typo", %{origin_kind: :human, source: "steward"}),
        assertion("b", "name", "Fixed", %{
          origin_kind: :human,
          source: "steward",
          observed_at: @late
        })
      ]

      assert %{merged: %{"name" => "Fixed"}} = Assertions.fold(%{}, assertions)
    end

    test "a refreshed import replaces what that source said before" do
      assertions = [
        assertion("a", "name", "Old Name"),
        assertion("b", "name", "New Name", %{observed_at: @late})
      ]

      assert %{merged: %{"name" => "New Name"}} = Assertions.fold(%{}, assertions)
    end

    test "another source's older value still wins under non_null" do
      assertions = [
        assertion("a", "name", "Held", %{source: "erp"}),
        assertion("b", "name", "First"),
        assertion("c", "name", "Second", %{observed_at: @late})
      ]

      assert %{merged: %{"name" => "Held"}} = Assertions.fold(%{}, assertions)
    end

    test "retracting the newest brings back the one before" do
      assertions = [
        assertion("a", "name", "Earlier"),
        assertion("b", "name", "Newest", %{observed_at: @late}),
        assertion("c", "name", nil, %{origin_kind: :retraction, retracts_id: "b", value: nil})
      ]

      assert %{merged: %{"name" => "Earlier"}} = Assertions.fold(%{}, assertions)
    end

    test "a newer statement waiting on a person doesn't displace the admitted one" do
      assertions = [
        assertion("a", "name", "Admitted"),
        assertion("b", "name", "Pending", %{band: :review, observed_at: @late})
      ]

      assert %{merged: %{"name" => "Admitted"}} = Assertions.fold(%{}, assertions)
    end

    test "one attribute's statement doesn't displace another's" do
      assertions = [
        assertion("a", "name", "Acme"),
        assertion("b", "email", "a@x.io", %{observed_at: @late})
      ]

      assert %{merged: %{"name" => "Acme", "email" => "a@x.io"}} =
               Assertions.fold(%{}, assertions)
    end

    test "the same source on an absorbed golden stays separate, so unmerge is intact" do
      assertions = [
        assertion("a", "name", "Survivor"),
        assertion("b", "name", "Absorbed", %{golden_id: @absorbed, observed_at: @late})
      ]

      depths = Assertions.chain_depths(@golden, [{@absorbed, @golden}])
      assert %{merged: %{"name" => "Survivor"}} = Assertions.fold(%{}, assertions, depths: depths)
    end

    test "origin kinds are separate speakers" do
      policy = %{"default" => "origin_rank", "origin_rank" => ["import", "enrichment"]}

      assertions = [
        assertion("a", "name", "Imported"),
        assertion("b", "name", "Enriched", %{origin_kind: :enrichment, observed_at: @late})
      ]

      assert %{merged: %{"name" => "Imported"}} = Assertions.fold(policy, assertions)
    end
  end

  describe "what does not compete" do
    test "no assertions fold to nothing" do
      assert Assertions.fold(%{}, []) == %{merged: %{}, provenance: %{}}
    end

    test "a retracted statement and its retraction" do
      assertions = [
        assertion("a", "name", "Wrong"),
        assertion("b", "name", "Right", %{observed_at: @late}),
        assertion("c", "name", nil, %{origin_kind: :retraction, retracts_id: "a", value: nil})
      ]

      assert %{merged: %{"name" => "Right"}} = Assertions.fold(%{}, assertions)
    end

    test "review and omit bands wait; admit competes" do
      assertions = [
        assertion("a", "name", "Pending", %{band: :review}),
        assertion("b", "name", "Refused", %{band: :omit}),
        assertion("c", "name", "Admitted", %{band: :admit, observed_at: @late})
      ]

      assert %{merged: %{"name" => "Admitted"}} = Assertions.fold(%{}, assertions)
    end

    test "only a review-band statement leaves the attribute absent" do
      assert Assertions.fold(%{}, [assertion("a", "tax_id", "123", %{band: :review})]) ==
               %{merged: %{}, provenance: %{}}
    end

    test "a blank string is no value" do
      assertions = [
        assertion("a", "name", "  "),
        assertion("b", "name", "Real", %{observed_at: @late})
      ]

      assert %{merged: %{"name" => "Real"}} = Assertions.fold(%{}, assertions)
    end

    test "false is a value" do
      assert %{merged: %{"active" => false}} =
               Assertions.fold(%{}, [assertion("a", "active", false)])
    end

    test "an expired statement still stands" do
      expired = assertion("a", "name", "Old", %{valid_until: @early})
      assert %{merged: %{"name" => "Old"}} = Assertions.fold(%{}, [expired])
    end
  end

  describe "strategies" do
    @policy %{"default" => "origin_rank", "origin_rank" => ["human", "import", "enrichment"]}

    test "origin_rank prefers the earliest-ranked origin over the oldest statement" do
      assertions = [
        assertion("a", "name", "Provider", %{origin_kind: :enrichment}),
        assertion("b", "name", "Person", %{origin_kind: :human, observed_at: @late})
      ]

      assert %{merged: %{"name" => "Person"}} = Assertions.fold(@policy, assertions)
    end

    test "an origin the list does not name ranks last" do
      assertions = [
        assertion("a", "name", "Inferred", %{origin_kind: :inference}),
        assertion("b", "name", "Provider", %{origin_kind: :enrichment, observed_at: @late})
      ]

      assert %{merged: %{"name" => "Provider"}} = Assertions.fold(@policy, assertions)
    end

    test "source_rank compares real source names" do
      policy = %{"default" => "source_rank", "source_rank" => ["erp", "crm"]}

      assertions = [
        assertion("a", "name", "Crm", %{source: "crm"}),
        assertion("b", "name", "Erp", %{source: "erp", observed_at: @late})
      ]

      assert %{merged: %{"name" => "Erp"}} = Assertions.fold(policy, assertions)
    end

    test "most_complete compares what each origin said as a whole" do
      ref = %{"landing" => "full"}
      policy = %{"default" => "most_complete"}

      assertions = [
        assertion("a", "name", "Thin"),
        assertion("b", "name", "Full", %{source: "erp", origin_ref: ref, observed_at: @late}),
        assertion("c", "email", "f@x.io", %{source: "erp", origin_ref: ref, observed_at: @late})
      ]

      assert %{merged: %{"name" => "Full"}} = Assertions.fold(policy, assertions)
    end
  end

  describe "provenance" do
    test "names the winning statement, its origin and the strategy" do
      assertions = [assertion("a", "name", "Acme", %{origin_kind: :human, source: "steward"})]

      assert %{provenance: %{"name" => entry}} = Assertions.fold(%{}, assertions)

      assert entry == %{
               "assertion_id" => "a",
               "origin" => "human",
               "source" => "steward",
               "strategy" => "non_null"
             }
    end
  end

  describe "a person's statement comes first" do
    test "a steward's new value beats an older import under non_null" do
      assertions = [
        assertion("a", "name", "Imported"),
        assertion("b", "name", "Stewarded", %{
          origin_kind: :human,
          source: "steward",
          observed_at: @late
        })
      ]

      assert %{merged: %{"name" => "Stewarded"}} = Assertions.fold(%{}, assertions)
    end

    test "among people, the oldest order still holds" do
      assertions = [
        assertion("b", "name", "Later", %{origin_kind: :human, source: "p2", observed_at: @late}),
        assertion("a", "name", "First", %{origin_kind: :human, source: "p1"})
      ]

      assert %{merged: %{"name" => "First"}} = Assertions.fold(%{}, assertions)
    end

    test "depth stays primary: a survivor's import beats an absorbed golden's person" do
      assertions = [
        assertion("a", "name", "Absorbed Person", %{golden_id: @absorbed, origin_kind: :human}),
        assertion("b", "name", "Survivor Import", %{observed_at: @late})
      ]

      depths = Assertions.chain_depths(@golden, [{@absorbed, @golden}])

      assert %{merged: %{"name" => "Survivor Import"}} =
               Assertions.fold(%{}, assertions, depths: depths)
    end

    test "steward_override through the fold names the human statement" do
      policy = %{"default" => "steward_override"}

      assertions = [
        assertion("a", "name", "Imported"),
        assertion("b", "name", "Stewarded", %{
          origin_kind: :human,
          source: "steward",
          observed_at: @late
        })
      ]

      assert %{
               merged: %{"name" => "Stewarded"},
               provenance: %{"name" => provenance}
             } = Assertions.fold(policy, assertions)

      assert provenance == %{
               "assertion_id" => "b",
               "origin" => "human",
               "source" => "steward",
               "strategy" => "steward_override"
             }
    end
  end

  describe "a same-observed_at correction" do
    @first_write ~U[2026-02-01 00:00:00.000000Z]
    @second_write ~U[2026-02-02 00:00:00.000000Z]

    test "the row written later wins, whatever its id says" do
      assertions = [
        assertion("zzz", "name", "Original", %{inserted_at: @first_write}),
        assertion("aaa", "name", "Corrected", %{inserted_at: @second_write})
      ]

      assert %{merged: %{"name" => "Corrected"}} = Assertions.fold(%{}, assertions)
    end

    test "with no inserted_at, id still orders it" do
      assertions = [
        assertion("a", "name", "Lower id"),
        assertion("b", "name", "Higher id")
      ]

      assert %{merged: %{"name" => "Higher id"}} = Assertions.fold(%{}, assertions)
    end
  end

  describe "most_complete across a correction" do
    @mid ~U[2026-03-01 00:00:00.000000Z]

    defp most_complete_statements do
      x = %{source: "x", observed_at: @mid, origin_ref: %{"landing" => "x1"}}
      correction = %{source: "x", observed_at: @late, origin_ref: %{"landing" => "x2"}}
      y = %{source: "y", origin_ref: %{"landing" => "y1"}}

      [
        assertion("y1", "name", "Y", y),
        assertion("y2", "email", "y@x.io", y),
        assertion("x1", "name", "X", x),
        assertion("x2", "email", "x@x.io", x),
        assertion("x3", "phone", "typo", x),
        assertion("x4", "phone", "555", correction)
      ]
    end

    test "correcting one field does not flip the most complete speaker" do
      assert %{merged: %{"name" => "X", "phone" => "555"}} =
               Assertions.fold(%{"default" => "most_complete"}, most_complete_statements())
    end

    test "most_recent still sees each record's own observed_at" do
      x_name = assertion("x1", "name", "X", %{source: "x"})
      x_phone = assertion("x2", "phone", "555", %{source: "x", observed_at: @late})
      y_name = assertion("y1", "name", "Y", %{source: "y", observed_at: @mid})

      assert %{merged: %{"name" => "Y"}} =
               Assertions.fold(%{"default" => "most_recent"}, [x_name, x_phone, y_name])
    end
  end

  describe "retractions" do
    defp retraction(id, retracts, overrides) do
      assertion(
        id,
        "name",
        nil,
        Map.merge(%{origin_kind: :retraction, retracts_id: retracts, value: nil}, overrides)
      )
    end

    @t1 ~U[2026-02-01 00:00:00.000000Z]
    @t2 ~U[2026-02-02 00:00:00.000000Z]
    @t3 ~U[2026-02-03 00:00:00.000000Z]

    test "a retraction waiting on a person does not take effect" do
      assertions = [assertion("a", "name", "Acme"), retraction("r", "a", %{band: :review})]
      assert %{merged: %{"name" => "Acme"}} = Assertions.fold(%{}, assertions)
    end

    test "a refused retraction does not take effect" do
      assertions = [assertion("a", "name", "Acme"), retraction("r", "a", %{band: :omit})]
      assert %{merged: %{"name" => "Acme"}} = Assertions.fold(%{}, assertions)
    end

    test "an admitted retraction takes effect" do
      assertions = [assertion("a", "name", "Acme"), retraction("r", "a", %{band: :admit})]
      assert Assertions.fold(%{}, assertions) == %{merged: %{}, provenance: %{}}
    end

    test "retracting a retraction restores its target" do
      assertions = [
        assertion("a", "name", "Acme"),
        retraction("r1", "a", %{observed_at: @t1}),
        retraction("r2", "r1", %{observed_at: @t2})
      ]

      assert %{merged: %{"name" => "Acme"}} = Assertions.fold(%{}, assertions)
    end

    test "retracting that withdraws the target again" do
      assertions = [
        assertion("a", "name", "Acme"),
        retraction("r1", "a", %{observed_at: @t1}),
        retraction("r2", "r1", %{observed_at: @t2}),
        retraction("r3", "r2", %{observed_at: @t3})
      ]

      assert Assertions.fold(%{}, assertions) == %{merged: %{}, provenance: %{}}
    end

    test "a retraction of a retraction waiting on a person changes nothing" do
      assertions = [
        assertion("a", "name", "Acme"),
        retraction("r1", "a", %{observed_at: @t1}),
        retraction("r2", "r1", %{observed_at: @t2, band: :review})
      ]

      assert Assertions.fold(%{}, assertions) == %{merged: %{}, provenance: %{}}
    end

    test "a chain folds the same in any input order" do
      assertions = [
        assertion("a", "name", "Acme"),
        retraction("r1", "a", %{observed_at: @t1}),
        retraction("r2", "r1", %{observed_at: @t2}),
        retraction("r3", "r2", %{observed_at: @t3})
      ]

      for shuffled <- [Enum.reverse(assertions), Enum.shuffle(assertions)] do
        assert Assertions.fold(%{}, shuffled) == Assertions.fold(%{}, assertions)
      end
    end

    test "two retractions naming each other: the newest stands, whatever the input order" do
      a = assertion("a", "name", "Acme")
      first = retraction("r1", "r2", %{observed_at: @t1})
      second = retraction("r2", "r1", %{observed_at: @t2})

      for assertions <- [[a, first, second], [second, first, a]] do
        assert %{merged: %{"name" => "Acme"}} = Assertions.fold(%{}, assertions)
      end

      target_of_newest = retraction("r2", "a", %{observed_at: @t2})
      older = retraction("r1", "r2", %{observed_at: @t1})

      assert Assertions.fold(%{}, [a, older, target_of_newest]) ==
               %{merged: %{}, provenance: %{}}
    end
  end

  describe "pending/1" do
    defp review(id, value, overrides \\ %{}) do
      assertion(id, "tax_id", value, Map.merge(%{band: :review}, overrides))
    end

    defp pending_ids(assertions),
      do: assertions |> Assertions.pending() |> Enum.map(& &1.id) |> Enum.sort()

    test "a statement superseded by the same source's newer one is not pending" do
      assert pending_ids([review("a", "1"), review("b", "2", %{observed_at: @late})]) == ["b"]
    end

    test "a newer admitted statement from the same source ends the wait" do
      assert pending_ids([
               review("a", "1"),
               assertion("b", "tax_id", "2", %{observed_at: @late})
             ]) == []
    end

    test "another source does not supersede it" do
      assert pending_ids([
               review("a", "1"),
               assertion("b", "tax_id", "2", %{source: "erp", observed_at: @late})
             ]) == ["a"]
    end

    test "another origin kind does not supersede it" do
      assert pending_ids([
               review("a", "1"),
               assertion("b", "tax_id", "2", %{origin_kind: :enrichment, observed_at: @late})
             ]) == ["a"]
    end

    test "another attribute or golden does not supersede it" do
      assert pending_ids([
               review("a", "1"),
               assertion("b", "email", "2", %{observed_at: @late}),
               assertion("c", "tax_id", "3", %{golden_id: @absorbed, observed_at: @late})
             ]) == ["a"]
    end

    test "a newer omitted statement does not supersede it" do
      assert pending_ids([
               review("a", "1"),
               assertion("b", "tax_id", "2", %{band: :omit, observed_at: @late})
             ]) == ["a"]
    end

    test "a newer statement that was retracted does not supersede it" do
      assert pending_ids([
               review("a", "1"),
               assertion("b", "tax_id", "2", %{observed_at: @late}),
               assertion("r", "tax_id", nil, %{
                 origin_kind: :retraction,
                 retracts_id: "b",
                 value: nil
               })
             ]) == ["a"]
    end

    test "a blank statement is never pending: it could not stand if admitted" do
      assert pending_ids([review("a", "   ")]) == []
    end

    test "a retraction waiting on a person is not pending once its target is gone" do
      assert pending_ids([
               assertion("target", "name", "Acme"),
               retraction("settled", "target", %{observed_at: @late}),
               retraction("waiting", "target", %{observed_at: @late, band: :review})
             ]) == []
    end

    test "a retraction waiting on a person leaves its target pending" do
      assert pending_ids([
               review("a", "1"),
               assertion("r", "tax_id", nil, %{
                 origin_kind: :retraction,
                 retracts_id: "a",
                 band: :review,
                 value: nil
               })
             ]) == ["a", "r"]
    end
  end

  describe "standing/3" do
    test "supporting holds every competing statement with the standing value, newest first" do
      assertions = [
        assertion("a", "name", "Acme"),
        assertion("b", "name", "Acme", %{source: "erp", observed_at: @late}),
        assertion("c", "name", "Other", %{source: "ops", observed_at: @late})
      ]

      assert %{supporting: %{"name" => [%{id: "b"}, %{id: "a"}]}} =
               Assertions.standing(%{}, assertions)
    end

    test "a statement that does not compete does not support" do
      assertions = [
        assertion("a", "name", "Acme"),
        assertion("b", "name", "Acme", %{source: "erp", band: :review, observed_at: @late})
      ]

      assert %{supporting: %{"name" => [%{id: "a"}]}} = Assertions.standing(%{}, assertions)
    end

    test "fold/3 still has only its two keys" do
      assert Assertions.fold(%{}, [assertion("a", "name", "Acme")]) |> Map.keys() |> Enum.sort() ==
               [:merged, :provenance]
    end

    test "nothing standing supports nothing" do
      assert %{supporting: supporting} = Assertions.standing(%{}, [])
      assert supporting == %{}
    end
  end

  describe "chain_depths/2" do
    test "the root alone is depth 0" do
      assert Assertions.chain_depths("a", []) == %{"a" => 0}
    end

    test "absorbed records deepen along the chain" do
      assert Assertions.chain_depths("a", [{"b", "a"}, {"c", "b"}, {"d", "a"}]) ==
               %{"a" => 0, "b" => 1, "c" => 2, "d" => 1}
    end

    test "a cycle ends the walk" do
      assert Assertions.chain_depths("a", [{"b", "a"}, {"a", "b"}]) == %{"a" => 0, "b" => 1}
    end

    test "records outside the chain are not reached" do
      assert Assertions.chain_depths("a", [{"x", "y"}]) == %{"a" => 0}
    end
  end

  describe "Survivorship.resolve/2" do
    test "keeps its two-key shape" do
      record = %{record: :r, source: "s", observed_at: nil, attributes: %{"a" => 1}}
      assert %{merged: %{"a" => 1}} = result = Survivorship.resolve(%{}, [record])
      assert Map.keys(result) |> Enum.sort() == [:merged, :provenance]
    end
  end

  describe "the incumbent option" do
    @held %{"held" => true}
    @old_import ~U[2024-01-01 00:00:00.000000Z]

    defp held?(assertion), do: assertion.origin_ref == @held

    defp held_and_history(extra \\ []) do
      [
        assertion("held", "name", "Held", %{
          origin_ref: @held,
          source: "golden",
          observed_at: @early
        }),
        assertion("old", "name", "History", %{source: "mail", observed_at: @old_import})
      ] ++ extra
    end

    test "the default lets older-dated history replace the held value" do
      assert %{merged: %{"name" => "History"}} = Assertions.fold(%{}, held_and_history())
    end

    test "an old-dated import loses to the incumbent under non_null" do
      assert %{merged: %{"name" => "Held"}, provenance: %{"name" => %{"assertion_id" => "held"}}} =
               Assertions.fold(%{}, held_and_history(), incumbent: &held?/1)
    end

    test "input order does not matter" do
      assert %{merged: %{"name" => "Held"}} =
               Assertions.fold(%{}, Enum.reverse(held_and_history()), incumbent: &held?/1)
    end

    test "a human statement beats the incumbent" do
      assertions =
        held_and_history([
          assertion("steward", "name", "Steward", %{
            origin_kind: :human,
            source: "steward",
            observed_at: @late
          })
        ])

      assert %{merged: %{"name" => "Steward"}} =
               Assertions.fold(%{}, assertions, incumbent: &held?/1)
    end

    test "depth beats the incumbent" do
      assertions = [
        assertion("held", "name", "Absorbed held", %{
          golden_id: @absorbed,
          origin_ref: @held,
          source: "golden"
        }),
        assertion("s", "name", "Survivor", %{observed_at: @late})
      ]

      depths = Assertions.chain_depths(@golden, [{@absorbed, @golden}])

      assert %{merged: %{"name" => "Survivor"}} =
               Assertions.fold(%{}, assertions, depths: depths, incumbent: &held?/1)
    end

    test "most_recent still takes the latest observation" do
      policy = %{"default" => "most_recent"}

      assert %{merged: %{"name" => "Held"}} =
               Assertions.fold(policy, held_and_history(), incumbent: &held?/1)
    end

    test "most_complete decides on completeness and the incumbent breaks ties" do
      policy = %{"default" => "most_complete"}

      assert %{merged: %{"name" => "Held"}} =
               Assertions.fold(policy, held_and_history(), incumbent: &held?/1)

      richer =
        held_and_history([
          assertion("e", "email", "a@x.io", %{source: "mail", observed_at: @old_import})
        ])

      assert %{merged: %{"name" => "History"}} =
               Assertions.fold(policy, richer, incumbent: &held?/1)
    end

    test "standing names the incumbent as the supporting statement" do
      assert %{statements: %{"name" => %{id: "held"}}} =
               Assertions.standing(%{}, held_and_history(), incumbent: &held?/1)
    end

    test "pending ignores the option's concerns" do
      review = assertion("r", "name", "Maybe", %{band: :review})
      assert [%{id: "r"}] = Assertions.pending(held_and_history([review]))
    end

    test "a non-function raises" do
      assert_raise ArgumentError, ~r/incumbent/, fn ->
        Assertions.fold(%{}, held_and_history(), incumbent: :yes)
      end

      assert_raise ArgumentError, fn ->
        Assertions.fold(%{}, held_and_history(), incumbent: fn _a, _b -> true end)
      end
    end

    test "absent option and a never-true function give the same fold" do
      assert Assertions.fold(%{}, held_and_history()) ==
               Assertions.fold(%{}, held_and_history(), incumbent: fn _ -> false end)
    end
  end
end
