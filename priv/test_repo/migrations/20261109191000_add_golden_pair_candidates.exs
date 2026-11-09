# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddGoldenPairCandidates do
  @moduledoc "A match candidate can pair two golden records."

  use Ecto.Migration

  def up do
    alter table(:mdm_match_candidates) do
      modify(:staged_record_id, :uuid, null: true)
      add(:other_golden_id, :uuid)
    end

    create constraint(:mdm_match_candidates, :exactly_one_pairing,
             check: "(staged_record_id IS NULL) <> (other_golden_id IS NULL)"
           )

    create unique_index(:mdm_match_candidates, [:golden_resource, :golden_id, :other_golden_id],
             where: "other_golden_id IS NOT NULL",
             name: :mdm_match_candidates_one_golden_pair_index
           )
  end

  def down do
    drop(
      index(:mdm_match_candidates, [:golden_resource, :golden_id, :other_golden_id],
        name: :mdm_match_candidates_one_golden_pair_index
      )
    )

    drop(constraint(:mdm_match_candidates, :exactly_one_pairing))

    alter table(:mdm_match_candidates) do
      remove(:other_golden_id)
      modify(:staged_record_id, :uuid, null: false)
    end
  end
end
