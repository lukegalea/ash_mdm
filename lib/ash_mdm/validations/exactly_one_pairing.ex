# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Validations.ExactlyOnePairing do
  @moduledoc """
  A match candidate pairs a golden with a staged record or with another
  golden, never both and never neither. Returns exceptions, not keyword
  errors, because a bulk create turns a keyword error into an unknown error.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    staged? = not is_nil(Ash.Changeset.get_attribute(changeset, :staged_record_id))
    other? = not is_nil(Ash.Changeset.get_attribute(changeset, :other_golden_id))

    case {staged?, other?} do
      {true, false} ->
        :ok

      {false, true} ->
        :ok

      {true, true} ->
        {:error,
         InvalidAttribute.exception(
           field: :other_golden_id,
           message: "a candidate pairs a staged record or a golden, not both"
         )}

      {false, false} ->
        {:error,
         InvalidAttribute.exception(
           field: :staged_record_id,
           message: "a candidate needs a staged record or another golden"
         )}
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
