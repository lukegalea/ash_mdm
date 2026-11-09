# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.HardenFoldAndDigest do
  @moduledoc """
  The one-active index on the rule set fixture, and the fixture tables for a
  tenanted rule set and a sensitive attribute assertion.
  """

  use Ecto.Migration

  def up do
    create(
      unique_index(:mdm_match_rule_sets, [:golden_resource],
        where: "status = 'active'",
        name: "mdm_match_rule_sets_one_active"
      )
    )

    create table(:mdm_tenant_match_rule_sets, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:organization_id, :uuid, null: false)
      add(:golden_resource, :text, null: false)
      add(:rules, :map, null: false)
      add(:survivorship, :map)
      add(:status, :text, null: false, default: "draft")
      add(:version, :integer, null: false, default: 1)
      add(:root_id, :uuid)
      add(:supersedes_id, :uuid)
      add(:content_hash, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:mdm_tenant_match_rule_sets, [:organization_id, :golden_resource],
        where: "status = 'active'",
        name: "mdm_tenant_match_rule_sets_one_active"
      )
    )

    create table(:mdm_sensitive_attribute_assertions, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:golden_resource, :text, null: false)
      add(:golden_id, :uuid, null: false)
      add(:attribute, :text, null: false)
      add(:value, :map)
      add(:origin_kind, :text, null: false)
      add(:origin_ref, :map, null: false)
      add(:source, :text, null: false)
      add(:band, :text)
      add(:confidence, :decimal)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:valid_until, :utc_datetime_usec)
      add(:retracts_id, :uuid)
      add(:content_digest, :text, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:mdm_sensitive_attribute_assertions, [:content_digest],
        name: "mdm_sensitive_attribute_assertions_one_statement_index"
      )
    )
  end

  def down do
    drop(table(:mdm_sensitive_attribute_assertions))
    drop(table(:mdm_tenant_match_rule_sets))
    drop(index(:mdm_match_rule_sets, [:golden_resource], name: "mdm_match_rule_sets_one_active"))
  end
end
