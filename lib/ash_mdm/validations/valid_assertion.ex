# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Validations.ValidAssertion do
  @moduledoc """
  An attribute assertion says something, or withdraws something, and says
  where that came from. A statement with no value is not a statement, and a
  retraction carries a target and no value.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    origin_ref = Ash.Changeset.get_attribute(changeset, :origin_ref)

    if is_map(origin_ref) and map_size(origin_ref) > 0 do
      validate_shape(
        Ash.Changeset.get_attribute(changeset, :origin_kind),
        Ash.Changeset.get_argument(changeset, :value),
        Ash.Changeset.get_attribute(changeset, :retracts_id)
      )
    else
      {:error, field: :origin_ref, message: "must say where this statement came from"}
    end
  end

  defp validate_shape(:retraction, value, retracts_id) do
    cond do
      is_nil(retracts_id) -> {:error, field: :retracts_id, message: "must name what it retracts"}
      not is_nil(value) -> {:error, field: :value, message: "a retraction carries no value"}
      true -> :ok
    end
  end

  defp validate_shape(_kind, value, retracts_id) do
    cond do
      not is_nil(retracts_id) ->
        {:error, field: :retracts_id, message: "only a retraction retracts"}

      blank?(value) ->
        {:error, field: :value, message: "a statement needs a value"}

      not match?({:ok, _}, Jason.encode(value)) ->
        {:error, field: :value, message: "must be JSON-encodable"}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
