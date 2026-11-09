# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.GoldenPairCandidateTest do
  @moduledoc "A match candidate pairing two golden records, and the staged path beside it."

  use ExUnit.Case, async: false

  alias AshMdm.Fixtures.MatchCandidate

  @moduletag :db

  @low "00000000-0000-0000-0000-000000000001"
  @high "ffffffff-ffff-ffff-ffff-ffffffffffff"
  @resource "AshMdm.Fixtures.Person"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp pair_input(overrides) do
    Map.merge(
      %{
        golden_resource: @resource,
        golden_id: @low,
        other_golden_id: @high,
        score: Decimal.new("0.9")
      },
      overrides
    )
  end

  defp create_pair(overrides \\ %{}),
    do:
      MatchCandidate
      |> Ash.Changeset.for_create(:create_golden_pair, pair_input(overrides))
      |> Ash.create()

  defp staged_input(overrides \\ %{}) do
    Map.merge(
      %{
        staged_record_id: Ash.UUID.generate(),
        golden_resource: @resource,
        golden_id: Ash.UUID.generate(),
        score: Decimal.new("0.5")
      },
      overrides
    )
  end

  defp invalid_fields({:error, %Ash.Error.Invalid{errors: errors}}),
    do:
      errors
      |> Enum.map(&(Map.get(&1, :field) || List.first(Map.get(&1, :fields, []))))
      |> Enum.sort()

  describe "golden pair" do
    test "is stored with no staged record" do
      assert {:ok, c} = create_pair()
      assert c.staged_record_id == nil
      assert {c.golden_id, c.other_golden_id} == {@low, @high}
      assert c.status == :pending
    end

    test "is stored in canonical order whichever way round it arrives" do
      assert {:ok, c} = create_pair(%{golden_id: @high, other_golden_id: @low})
      assert {c.golden_id, c.other_golden_id} == {@low, @high}
    end

    test "reversed pair is one row" do
      assert {:ok, _} = create_pair()
      assert {:error, _} = create_pair(%{golden_id: @high, other_golden_id: @low})
      assert [_] = Ash.read!(MatchCandidate)
    end

    test "a self-pair is refused" do
      assert {:error, _} = result = create_pair(%{other_golden_id: @low})
      assert :other_golden_id in invalid_fields(result)
      assert Ash.read!(MatchCandidate) == []
    end

    test "the same pair under another golden resource is a different candidate" do
      assert {:ok, _} = create_pair()
      assert {:ok, _} = create_pair(%{golden_resource: "Other"})
    end

    test "a missing other golden is refused" do
      result = create_pair(%{other_golden_id: nil})
      assert {:error, _} = result
      assert :other_golden_id in invalid_fields(result)
    end

    test "a missing golden is refused" do
      result = create_pair(%{golden_id: nil})
      assert :golden_id in invalid_fields(result)
    end

    test "a malformed other golden is refused" do
      result = create_pair(%{other_golden_id: "not-a-uuid"})
      assert :other_golden_id in invalid_fields(result)
    end

    test "a staged record is not accepted on a golden pair" do
      result = create_pair(%{staged_record_id: Ash.UUID.generate()})
      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "an unknown input is refused" do
      assert {:error, %Ash.Error.Invalid{}} = create_pair(%{bogus: 1})
    end

    test "a missing score is refused" do
      assert :score in invalid_fields(create_pair(%{score: nil}))
    end
  end

  describe "exactly one of staged record and other golden" do
    test "both set is refused by the validation" do
      result =
        MatchCandidate
        |> Ash.Changeset.for_create(:create, staged_input())
        |> Ash.Changeset.force_change_attribute(:other_golden_id, Ash.UUID.generate())
        |> Ash.create()

      assert :other_golden_id in invalid_fields(result)
    end

    test "neither set is refused by the validation" do
      result =
        MatchCandidate
        |> Ash.Changeset.for_create(:create, staged_input(%{staged_record_id: nil}))
        |> Ash.create()

      assert :staged_record_id in invalid_fields(result)
    end

    test "the database refuses both set" do
      assert_raise Postgrex.Error, ~r/exactly_one_pairing/, fn ->
        insert_raw(Ash.UUID.generate(), Ash.UUID.generate())
      end
    end

    test "the database refuses neither set" do
      assert_raise Postgrex.Error, ~r/exactly_one_pairing/, fn -> insert_raw(nil, nil) end
    end

    test "the database refuses a second golden pair row, however it was written" do
      insert_raw(nil, @high)
      assert_raise Postgrex.Error, ~r/one_golden_pair/, fn -> insert_raw(nil, @high) end
    end
  end

  describe "staged candidates" do
    test "are created as before" do
      input = staged_input()
      assert {:ok, c} = MatchCandidate |> Ash.Changeset.for_create(:create, input) |> Ash.create()
      assert c.other_golden_id == nil
      assert c.staged_record_id == input.staged_record_id
      assert c.golden_id == input.golden_id
    end

    test "still hold one row per staged record and golden" do
      input = staged_input()
      assert {:ok, _} = MatchCandidate |> Ash.Changeset.for_create(:create, input) |> Ash.create()

      assert {:error, _} =
               MatchCandidate |> Ash.Changeset.for_create(:create, input) |> Ash.create()
    end

    test "do not accept a golden pair's other golden" do
      assert {:error, %Ash.Error.Invalid{}} =
               MatchCandidate
               |> Ash.Changeset.for_create(:create, staged_input(%{other_golden_id: @high}))
               |> Ash.create()
    end

    test "many staged rows may share a golden, and a golden pair may share it too" do
      golden = Ash.UUID.generate()

      for _ <- 1..2,
          do:
            MatchCandidate
            |> Ash.Changeset.for_create(:create, staged_input(%{golden_id: golden}))
            |> Ash.create!()

      assert {:ok, _} = create_pair(%{golden_id: golden})
    end

    test "the machine update still banding" do
      c = MatchCandidate |> Ash.Changeset.for_create(:create, staged_input()) |> Ash.create!()
      assert {:ok, u} = c |> Ash.Changeset.for_update(:update, %{band: :review}) |> Ash.update()
      assert u.band == :review

      assert {:error, _} =
               c |> Ash.Changeset.for_update(:update, %{status: :confirmed}) |> Ash.update()
    end
  end

  defp insert_raw(staged, other) do
    Ecto.Adapters.SQL.query!(
      AshMdm.Test.Repo,
      """
      INSERT INTO mdm_match_candidates
        (staged_record_id, golden_resource, golden_id, other_golden_id, score, inserted_at, updated_at)
      VALUES ($1, 'raw', $2, $3, 1, now(), now())
      """,
      [uuid(staged), Ecto.UUID.dump!(@low), uuid(other)]
    )
  end

  defp uuid(nil), do: nil
  defp uuid(value), do: Ecto.UUID.dump!(value)
end
