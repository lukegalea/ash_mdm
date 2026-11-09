# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Validations.DistinctGoldenPair do
  @moduledoc "A golden is never its own duplicate."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    golden_id = Ash.Changeset.get_attribute(changeset, :golden_id)

    if not is_nil(golden_id) and
         golden_id == Ash.Changeset.get_attribute(changeset, :other_golden_id),
       do: {:error, field: :other_golden_id, message: "a golden cannot be paired with itself"},
       else: :ok
  end
end
