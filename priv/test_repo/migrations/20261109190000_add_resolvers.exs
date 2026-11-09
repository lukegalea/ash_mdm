# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddResolvers do
  @moduledoc "The fixture tables for the resolver macro, plain and tenanted."

  use Ecto.Migration

  def up do
    for {table, tenant?} <- [{:mdm_resolvers, false}, {:mdm_tenant_resolvers, true}] do
      create table(table, primary_key: false) do
        add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
        if tenant?, do: add(:organization_id, :uuid, null: false)
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

      columns =
        if tenant?,
          do: [:organization_id, :golden_resource, :name],
          else: [:golden_resource, :name]

      create(
        unique_index(table, columns, where: "status = 'active'", name: "#{table}_one_active")
      )
    end
  end

  def down do
    drop(table(:mdm_tenant_resolvers))
    drop(table(:mdm_resolvers))
  end
end
