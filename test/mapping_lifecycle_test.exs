# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.LifecycleTest do
  @moduledoc """
  The version-chain lifecycle against the real database: draft -> validated
  -> activate (supersedes), the one-active partial index, create_version.
  """

  use ExUnit.Case, async: false

  @moduletag :db

  import AshMdm.TestHelpers

  alias AshMdm.Fixtures.Mapping

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp valid_rules do
    [
      %{"path" => "Email", "target" => "email", "op" => "trim", "args" => %{}},
      %{"path" => "Full Name", "target" => "name", "op" => "identity", "args" => %{}},
      %{
        "path" => nil,
        "target" => "tier",
        "op" => "unmapped",
        "args" => %{},
        "because" => "not carried"
      },
      %{
        "path" => nil,
        "target" => "joined_on",
        "op" => "unmapped",
        "args" => %{},
        "because" => "not carried"
      }
    ]
  end

  test "content_hash is stamped from canonical field_rules" do
    mapping = draft!(field_rules: valid_rules())

    assert mapping.content_hash == AshMdm.Mapping.ContentHash.hash!(valid_rules())
  end

  test "a fresh chain roots at its own id" do
    mapping = draft!(field_rules: valid_rules())

    assert mapping.root_id == mapping.id
    assert mapping.version == 1
  end

  test "validate transitions draft -> validated on a good mapping and stores findings" do
    mapping = draft!(field_rules: valid_rules())
    validated = validate!(mapping)

    assert validated.status == :validated
    assert %{"errors" => [], "warnings" => []} = stringify_keys(validated.validation_findings)
  end

  test "validate keeps a bad mapping a draft, with its findings" do
    bad_rules = [%{"path" => "Email", "target" => "email", "op" => "identity", "args" => %{}}]

    mapping = draft!(field_rules: bad_rules)
    still_draft = validate!(mapping)

    assert still_draft.status == :draft
    errors = stringify_keys(still_draft.validation_findings)["errors"]
    assert Enum.any?(errors, &(&1["check"] == "unaccounted_target"))
  end

  test "activate supersedes: the previous active version retires" do
    v1 = draft!(field_rules: valid_rules()) |> activate_validated!()

    v2 =
      Mapping
      |> Ash.Changeset.for_create(
        :create_version,
        %{
          from_mapping_id: v1.id,
          direction: :ingress,
          source: v1.source,
          stream: v1.stream,
          target_resource: v1.target_resource,
          field_rules: valid_rules(),
          observed_schema: %{}
        },
        authorize?: false
      )
      |> Ash.create!()

    assert v2.version == 2
    assert v2.supersedes_id == v1.id
    assert v2.root_id == v1.root_id

    v2 = v2 |> validate!() |> Ash.reload!() |> activate!()

    assert v2.status == :active
    assert Ash.reload!(v1).status == :retired

    actives = active_mappings(v2)
    assert length(actives) == 1
    assert hd(actives).id == v2.id
  end

  test "the one-active partial unique index is the database backstop" do
    v1 = draft!(field_rules: valid_rules()) |> activate_validated!()

    # Force a second active through a raw create (bypassing the change that
    # would retire v1): the index must refuse it.
    assert_raise Ash.Error.Invalid, fn ->
      Mapping
      |> Ash.Changeset.for_create(:draft, %{
        direction: :ingress,
        source: v1.source,
        stream: v1.stream,
        target_resource: v1.target_resource,
        field_rules: valid_rules()
      })
      |> Ash.Changeset.change_attribute(:status, :active)
      |> Ash.Changeset.change_attribute(:content_hash, "forced")
      |> Ash.create!(authorize?: false)
    end
  end

  test "a distinct identity tuple can be active at the same time" do
    _a = draft!(field_rules: valid_rules()) |> activate_validated!()

    b =
      draft!(stream: "other_stream", field_rules: valid_rules())
      |> activate_validated!()

    assert b.status == :active
    # Two active rows, one per tuple — the index is per-tuple, not global.
    assert length(active_mappings(b)) == 1
    assert Ash.reload!(_a).status == :active
  end

  test "a MatchRuleSet activates and supersedes per golden resource" do
    alias AshMdm.Fixtures.MatchRuleSet

    rules = [
      %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}
    ]

    v1 =
      MatchRuleSet
      |> Ash.Changeset.for_create(:draft, %{golden_resource: "Person", rules: rules},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    v1 =
      v1
      |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

    v2 =
      MatchRuleSet
      |> Ash.Changeset.for_create(:draft, %{golden_resource: "Person", rules: rules},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
      |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

    assert v2.status == :active
    assert Ash.reload!(v1).status == :retired
  end

  test "an unknown survivorship strategy is refused at activation" do
    alias AshMdm.Fixtures.MatchRuleSet

    rules = [%{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}]

    draft =
      MatchRuleSet
      |> Ash.Changeset.for_create(
        :draft,
        %{
          golden_resource: "Person",
          rules: rules,
          survivorship: %{"default" => "most_recnt", "source_rank" => ["sf"]}
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             draft
             |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
             |> Ash.update(authorize?: false)

    assert Enum.any?(errors, fn e ->
             e.message =~ "unknown survivorship strategies" and e.message =~ "most_recnt"
           end)
  end

  test "retire moves an active version out" do
    v1 = draft!(field_rules: valid_rules()) |> activate_validated!()
    retired = v1 |> Ash.Changeset.for_update(:retire, %{}, authorize?: false) |> Ash.update!()

    assert retired.status == :retired
  end
end
