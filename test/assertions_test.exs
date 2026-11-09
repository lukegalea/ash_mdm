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
        assertion("b", "name", "Later", %{observed_at: @late}),
        assertion("a", "name", "Held")
      ]

      assert %{merged: %{"name" => "Held"}} = Assertions.fold(%{}, assertions)
    end

    test "input order does not matter" do
      one = assertion("a", "name", "Held")
      two = assertion("b", "name", "Later", %{observed_at: @late})

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
        assertion("b", "name", "Full", %{origin_ref: ref, observed_at: @late}),
        assertion("c", "email", "f@x.io", %{origin_ref: ref, observed_at: @late})
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
end
