# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddCompleteness do
  @moduledoc "The fixture tables for the completeness macros."

  use Ecto.Migration

  def up do
    create table(:mdm_completeness_profiles, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:golden_resource, :text, null: false)
      add(:purpose, :text, null: false)
      add(:requirements, {:array, :map}, null: false)
      add(:status, :text, null: false, default: "draft")
      add(:version, :bigint, null: false, default: 1)
      add(:root_id, :uuid)
      add(:supersedes_id, :uuid)
      add(:content_hash, :text)
      add(:validation_findings, :map)
      add(:activation_note, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:mdm_completeness_profiles, [:golden_resource, :purpose],
        where: "status = 'active'",
        name: "mdm_completeness_profiles_one_active"
      )
    )

    create table(:mdm_attribute_gaps, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:golden_resource, :text, null: false)
      add(:golden_id, :uuid, null: false)
      add(:profile_id, :uuid, null: false)
      add(:profile_version, :bigint, null: false)
      add(:purpose, :text, null: false)
      add(:attribute, :text, null: false)
      add(:because, :text, null: false)
      add(:material, :boolean, null: false, default: false)
      add(:max_age_days, :bigint)
      add(:accepted_origins, {:array, :text})
      add(:has_value, :boolean, null: false, default: false)
      add(:standing_origin, :text)
      add(:observed_at, :utc_datetime_usec)
      add(:valid_until, :utc_datetime_usec)
      add(:assertion_id, :uuid)
      add(:pending_count, :bigint, null: false, default: 0)

      add(:refreshed_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:mdm_attribute_gaps, [:golden_resource, :golden_id, :profile_id, :attribute],
        name: "mdm_attribute_gaps_one_requirement_index"
      )
    )

    create(
      index(:mdm_attribute_gaps, [:golden_resource, :golden_id],
        name: "mdm_attribute_gaps_of_golden"
      )
    )
  end

  def down do
    drop(table(:mdm_attribute_gaps))
    drop(table(:mdm_completeness_profiles))
  end
end
