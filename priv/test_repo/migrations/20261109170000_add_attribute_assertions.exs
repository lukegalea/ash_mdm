# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddAttributeAssertions do
  @moduledoc "The fixture table for the attribute assertion macro."

  use Ecto.Migration

  def up do
    create table(:mdm_attribute_assertions, primary_key: false) do
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
      unique_index(:mdm_attribute_assertions, [:content_digest],
        name: "mdm_attribute_assertions_one_statement_index"
      )
    )

    create(
      index(:mdm_attribute_assertions, [:golden_resource, :golden_id, :attribute],
        name: "mdm_attribute_assertions_statements_of"
      )
    )
  end

  def down do
    drop(table(:mdm_attribute_assertions))
  end
end
