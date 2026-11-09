# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddResolvers do
  @moduledoc "The fixture table for the resolver macro."

  use Ecto.Migration

  def up do
    create table(:mdm_resolvers, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:golden_resource, :text, null: false)
      add(:name, :text, null: false)
      add(:kind, :text, null: false)
      add(:produces, {:array, :text}, null: false)
      add(:requires, {:array, :text}, null: false, default: [])
      add(:cost_rank, :bigint, null: false)
      add(:reference, :map, null: false)
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
      unique_index(:mdm_resolvers, [:golden_resource, :name],
        where: "status = 'active'",
        name: "mdm_resolvers_one_active"
      )
    )
  end

  def down do
    drop(table(:mdm_resolvers))
  end
end
