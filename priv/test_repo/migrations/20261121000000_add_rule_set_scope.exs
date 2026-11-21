# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddRuleSetScope do
  @moduledoc """
  A rule set's scope, and the one-active index widened to (golden resource,
  scope) on both rule set fixture tables. Existing rows take the empty scope.
  """

  use Ecto.Migration

  def up do
    for {table, cols} <- tables() do
      alter table(table) do
        add(:scope, :text, null: false, default: "")
      end

      drop(index(table, cols, name: "#{table}_one_active"))

      create(
        unique_index(table, cols ++ [:scope],
          where: "status = 'active'",
          name: "#{table}_one_active"
        )
      )
    end
  end

  def down do
    for {table, cols} <- tables() do
      drop(index(table, cols ++ [:scope], name: "#{table}_one_active"))

      create(unique_index(table, cols, where: "status = 'active'", name: "#{table}_one_active"))

      alter table(table) do
        remove(:scope)
      end
    end
  end

  defp tables do
    [
      {:mdm_match_rule_sets, [:golden_resource]},
      {:mdm_tenant_match_rule_sets, [:organization_id, :golden_resource]}
    ]
  end
end
