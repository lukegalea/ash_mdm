# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.CompletenessProfileTest do
  @moduledoc "The profile lifecycle and the projected gap row, against the database."

  use ExUnit.Case, async: false

  alias AshMdm.Completeness
  alias AshMdm.Fixtures.AttributeGap
  alias AshMdm.Fixtures.CompletenessProfile, as: Profile

  @moduletag :db
  @golden "AshMdm.Fixtures.Person"

  require Ash.Query

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp entry(attribute, need \\ "out_of_scope", extra \\ %{}) do
    Map.merge(%{"attribute" => attribute, "need" => need, "because" => "reason"}, extra)
  end

  defp total(overrides \\ %{}) do
    Enum.map(~w(name email tier joined_on), &Map.get(overrides, &1, entry(&1)))
  end

  defp draft!(requirements, purpose \\ "payment") do
    Profile
    |> Ash.Changeset.for_create(:draft, %{
      golden_resource: @golden,
      purpose: purpose,
      requirements: requirements
    })
    |> Ash.create!(authorize?: false)
  end

  defp run(profile, action, input \\ %{}) do
    profile |> Ash.Changeset.for_update(action, input) |> Ash.update!(authorize?: false)
  end

  describe "validate" do
    test "total accounting moves a draft to validated" do
      assert %{status: :validated} = total() |> draft!() |> run(:validate)
    end

    test "an unaccounted attribute stays a draft and says which" do
      profile = [entry("name")] |> draft!() |> run(:validate)

      assert profile.status == :draft
      assert "unaccounted_attribute" in checks_of(profile)
    end

    test "refuses an attribute the golden does not have" do
      profile = (total() ++ [entry("nickname")]) |> draft!() |> run(:validate)
      assert "unknown_attribute" in checks_of(profile)
    end

    test "refuses an entry with no because" do
      requirements = total(%{"name" => %{"attribute" => "name", "need" => "required"}})
      assert "without_because" in checks_of(requirements |> draft!() |> run(:validate))
    end

    test "refuses an unknown need" do
      requirements = total(%{"name" => entry("name", "mandatory")})
      assert "unknown_need" in checks_of(requirements |> draft!() |> run(:validate))
    end

    test "refuses the same attribute twice" do
      profile = (total() ++ [entry("name")]) |> draft!() |> run(:validate)
      assert "duplicate_attribute" in checks_of(profile)
    end

    test "refuses a max age that is not a positive whole number" do
      requirements = total(%{"name" => entry("name", "required", %{"max_age_days" => 0})})
      assert "bad_max_age" in checks_of(requirements |> draft!() |> run(:validate))
    end

    test "refuses an unknown accepted origin" do
      requirements = total(%{"name" => entry("name", "required", %{"accepted_origins" => ["x"]})})
      assert "bad_accepted_origins" in checks_of(requirements |> draft!() |> run(:validate))
    end

    test "refuses retraction as an accepted origin" do
      requirements =
        total(%{"name" => entry("name", "required", %{"accepted_origins" => ["retraction"]})})

      assert "bad_accepted_origins" in checks_of(requirements |> draft!() |> run(:validate))
    end

    test "refuses a qualifier on something not required" do
      requirements = total(%{"name" => entry("name", "optional", %{"material" => true})})
      assert "qualifier_on_unrequired" in checks_of(requirements |> draft!() |> run(:validate))
    end

    test "refuses a golden the host has not allowed" do
      profile =
        Profile
        |> Ash.Changeset.for_create(:draft, %{
          golden_resource: "Nope",
          purpose: "payment",
          requirements: []
        })
        |> Ash.create!(authorize?: false)
        |> run(:validate)

      assert "unknown_target" in checks_of(profile)
    end
  end

  describe "activate" do
    test "needs a validated profile" do
      assert_raise Ash.Error.Invalid, fn -> total() |> draft!() |> run(:activate) end
    end

    test "a new version retires its predecessor and keeps the chain" do
      first = total() |> draft!() |> run(:validate) |> run(:activate)

      second =
        Profile
        |> Ash.Changeset.for_create(:create_version, %{
          from_profile_id: first.id,
          requirements: total(%{"name" => entry("name", "required")})
        })
        |> Ash.create!(authorize?: false)
        |> run(:validate)
        |> run(:activate)

      assert second.golden_resource == @golden
      assert second.purpose == "payment"
      assert second.version == 2
      assert second.root_id == first.id
      assert second.supersedes_id == first.id
      assert second.status == :active
      assert %{status: :retired} = Ash.get!(Profile, first.id, authorize?: false)
    end

    test "a version cannot move to another purpose" do
      first = total() |> draft!()

      assert_raise Ash.Error.Invalid, fn ->
        Profile
        |> Ash.Changeset.for_create(:create_version, %{
          from_profile_id: first.id,
          purpose: "other",
          requirements: total()
        })
        |> Ash.create!(authorize?: false)
      end
    end

    test "another purpose stays active alongside" do
      total() |> draft!("payment") |> run(:validate) |> run(:activate)
      total() |> draft!("onboarding") |> run(:validate) |> run(:activate)

      active = Profile |> Ash.Query.filter(status == :active) |> Ash.read!(authorize?: false)
      assert length(active) == 2
    end
  end

  describe "the gap row" do
    @now DateTime.utc_now()

    defp project!(assessment_overrides) do
      profile_id = Ash.UUID.generate()

      AttributeGap
      |> Ash.Changeset.for_create(
        :project,
        Map.merge(
          %{
            golden_resource: @golden,
            golden_id: Ash.UUID.generate(),
            profile_id: profile_id,
            profile_version: 1,
            purpose: "payment",
            attribute: "name",
            because: "reason",
            has_value: true,
            standing_origin: "import",
            observed_at: DateTime.add(@now, -1, :day)
          },
          assessment_overrides
        )
      )
      |> Ash.create!(authorize?: false)
    end

    defp gap_kind(row), do: Ash.load!(row, :gap_kind, authorize?: false).gap_kind

    test "reads satisfied" do
      assert gap_kind(project!(%{})) == :satisfied
    end

    test "reads missing" do
      assert gap_kind(project!(%{has_value: false, standing_origin: nil, observed_at: nil})) ==
               :missing
    end

    test "reads origin not accepted" do
      assert gap_kind(project!(%{accepted_origins: ["human"]})) == :origin_not_accepted
    end

    test "reads expired" do
      assert gap_kind(project!(%{valid_until: DateTime.add(@now, -1, :hour)})) == :expired
    end

    test "reads stale, with nothing having written since" do
      row = project!(%{max_age_days: 30, observed_at: DateTime.add(@now, -60, :day)})
      assert gap_kind(row) == :stale
    end

    test "a value with no recorded origin is not accepted" do
      row = project!(%{standing_origin: nil, accepted_origins: ["human"]})
      assert gap_kind(row) == :origin_not_accepted
    end

    defp set_session_time_zone(zone) do
      Ecto.Adapters.SQL.query!(AshMdm.Test.Repo, "SET LOCAL TIME ZONE '#{zone}'")
    end

    test "staleness reads the same in a session east of UTC" do
      set_session_time_zone("Asia/Tokyo")

      row = project!(%{max_age_days: 30, observed_at: hours_ago(30 * 24 - 5)})
      assert gap_kind(row) == :satisfied
    end

    test "staleness reads the same in a session west of UTC" do
      set_session_time_zone("America/New_York")

      row = project!(%{max_age_days: 30, observed_at: hours_ago(30 * 24 + 1)})
      assert gap_kind(row) == :stale
    end

    test "expiry reads the same in a session west of UTC" do
      set_session_time_zone("America/New_York")

      assert gap_kind(project!(%{valid_until: hours_ago(1)})) == :expired
    end

    test "expiry reads the same in a session east of UTC" do
      set_session_time_zone("Asia/Tokyo")

      assert gap_kind(project!(%{valid_until: hours_ago(-1)})) == :satisfied
    end

    defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours, :hour)

    test "can be filtered, which a manual read could not" do
      golden_id = Ash.UUID.generate()
      project!(%{golden_id: golden_id, has_value: false, standing_origin: nil, observed_at: nil})
      project!(%{golden_id: golden_id, attribute: "email"})

      assert [%{attribute: "name"}] =
               AttributeGap
               |> Ash.Query.filter(golden_id == ^golden_id and gap_kind == :missing)
               |> Ash.read!(authorize?: false)
    end

    test "projecting again updates the one row" do
      first = project!(%{})

      second =
        project!(%{
          golden_id: first.golden_id,
          profile_id: first.profile_id,
          has_value: false,
          standing_origin: nil,
          observed_at: nil
        })

      assert second.id == first.id
      assert gap_kind(second) == :missing
    end

    test "has no attribute that could hold a value" do
      names = AttributeGap |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
      refute :value in names
    end

    test "the projection and the pure assessment use one vocabulary" do
      assert Ash.Resource.Info.calculation(AttributeGap, :gap_kind).constraints[:one_of] ==
               Completeness.kinds()
    end
  end

  defp checks_of(profile) do
    findings = profile.validation_findings
    errors = findings[:errors] || findings["errors"] || []
    Enum.map(errors, &to_string(&1[:check] || &1["check"]))
  end
end
