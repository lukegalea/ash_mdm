# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.AttributeAssertionTest do
  @moduledoc "The attribute assertion macro against the real database."

  use ExUnit.Case, async: false

  alias AshMdm.Assertions
  alias AshMdm.Fixtures.AttributeAssertion
  alias AshMdm.Fixtures.MatchRuleSet

  @moduletag :db

  require Ash.Query

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        golden_resource: "AshMdm.Fixtures.Person",
        golden_id: Ash.UUID.generate(),
        attribute: "name",
        value: "Acme",
        origin_kind: :import,
        origin_ref: %{"landing" => "l-1"},
        source: "crm",
        observed_at: ~U[2026-01-01 00:00:00.000000Z]
      },
      overrides
    )
  end

  defp assert_statement(input) do
    AttributeAssertion
    |> Ash.Changeset.for_create(:assert, input)
    |> Ash.create(authorize?: false)
  end

  defp assert_statement!(input) do
    {:ok, row} = assert_statement(input)
    row
  end

  defp count(golden_id) do
    AttributeAssertion
    |> Ash.Query.filter(golden_id == ^golden_id)
    |> Ash.count!(authorize?: false)
  end

  test "stores the value wrapped and reads back through the fold" do
    input = base()
    row = assert_statement!(input)

    assert row.value == %{"v" => "Acme"}
    assert %{merged: %{"name" => "Acme"}} = Assertions.fold(%{}, [row])
  end

  test "writing the same statement twice is one row" do
    input = base()
    assert_statement!(input)
    assert {:ok, _} = assert_statement(input)

    assert count(input.golden_id) == 1
  end

  test "a different value from the same origin is a new statement" do
    input = base()
    assert_statement!(input)
    assert_statement!(%{input | value: "Acme Inc"})

    assert count(input.golden_id) == 2
  end

  test "has no update action" do
    refute Enum.any?(Ash.Resource.Info.actions(AttributeAssertion), &(&1.type == :update))
  end

  test "a retraction withdraws a statement" do
    input = base()
    target = assert_statement!(input)

    retraction =
      assert_statement!(
        input
        |> Map.delete(:value)
        |> Map.merge(%{origin_kind: :retraction, retracts_id: target.id})
      )

    assert retraction.value == nil
    assert Assertions.fold(%{}, [target, retraction]) == %{merged: %{}, provenance: %{}}
  end

  test ":erase removes a statement" do
    input = base()
    row = assert_statement!(input)

    row |> Ash.Changeset.for_destroy(:erase) |> Ash.destroy!(authorize?: false)

    assert count(input.golden_id) == 0
  end

  describe "refuses" do
    test "a statement with no origin" do
      assert {:error, _} = assert_statement(base(%{origin_ref: %{}}))
    end

    test "an unknown origin kind" do
      assert {:error, _} = assert_statement(base(%{origin_kind: :guess}))
    end

    test "a statement with no value" do
      assert {:error, _} = assert_statement(Map.delete(base(), :value))
    end

    test "a blank value" do
      assert {:error, _} = assert_statement(base(%{value: "   "}))
    end

    test "a retraction with no target" do
      assert {:error, _} =
               assert_statement(
                 base()
                 |> Map.delete(:value)
                 |> Map.put(:origin_kind, :retraction)
               )
    end

    test "a retraction carrying a value" do
      assert {:error, _} =
               assert_statement(
                 base(%{origin_kind: :retraction, retracts_id: Ash.UUID.generate()})
               )
    end

    test "a retracts_id on an ordinary statement" do
      assert {:error, _} = assert_statement(base(%{retracts_id: Ash.UUID.generate()}))
    end

    test "a confidence outside 0..1" do
      assert {:error, _} = assert_statement(base(%{confidence: Decimal.new("1.5")}))
    end
  end

  describe "rule set activation and origin_rank" do
    defp draft(survivorship) do
      MatchRuleSet
      |> Ash.Changeset.for_create(:draft, %{
        golden_resource: "golden-#{System.unique_integer([:positive])}",
        rules: [%{"name" => "n", "kind" => "exact", "fields" => ["name"]}],
        survivorship: survivorship
      })
      |> Ash.create!(authorize?: false)
    end

    defp activate(rule_set) do
      rule_set |> Ash.Changeset.for_update(:activate) |> Ash.update(authorize?: false)
    end

    test "accepts a declared order of known origins" do
      assert {:ok, %{status: :active}} =
               activate(
                 draft(%{"default" => "origin_rank", "origin_rank" => ["human", "import"]})
               )
    end

    test "refuses origin_rank with no order" do
      assert {:error, _} = activate(draft(%{"default" => "origin_rank"}))
    end

    test "refuses an empty order on an attribute strategy" do
      assert {:error, _} =
               activate(
                 draft(%{
                   "attributes" => %{"name" => %{"strategy" => "origin_rank"}},
                   "origin_rank" => []
                 })
               )
    end

    test "refuses an unknown origin in the order" do
      assert {:error, _} =
               activate(draft(%{"default" => "origin_rank", "origin_rank" => ["guess"]}))
    end

    test "refuses retraction as a rank" do
      assert {:error, _} =
               activate(draft(%{"default" => "origin_rank", "origin_rank" => ["retraction"]}))
    end

    test "a policy without origin_rank is untouched" do
      assert {:ok, %{status: :active}} = activate(draft(%{"default" => "non_null"}))
    end
  end
end
