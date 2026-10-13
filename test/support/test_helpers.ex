# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.TestHelpers do
  @moduledoc "Shared fixture shorthands for the suite."

  require Ash.Query

  alias AshMdm.Fixtures.Mapping

  def draft!(opts) do
    attrs =
      Keyword.merge(
        [
          direction: :ingress,
          source: "manual_csv",
          stream: "acme_contacts",
          target_resource: "AshMdm.Fixtures.Person",
          field_rules: [],
          observed_schema: %{}
        ],
        opts
      )
      |> Map.new()

    Mapping
    |> Ash.Changeset.for_create(:draft, attrs, authorize?: false)
    |> Ash.create!()
  end

  def validate!(mapping) do
    mapping
    |> Ash.Changeset.for_update(:validate, %{}, authorize?: false)
    |> Ash.update!()
  end

  def activate!(mapping) do
    mapping
    |> Ash.Changeset.for_update(:activate, %{activation_note: "test"}, authorize?: false)
    |> Ash.update!()
  end

  @doc "validate then activate — the full person gate path."
  def activate_validated!(mapping) do
    mapping |> validate!() |> Ash.reload!() |> activate!()
  end

  def active_mappings(sample) do
    Mapping
    |> Ash.Query.filter(
      direction == ^sample.direction and source == ^sample.source and
        stream == ^sample.stream and target_resource == ^sample.target_resource and
        status == :active
    )
    |> Ash.read!(authorize?: false)
  end

  def stringify_keys(nil), do: nil

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  def stringify_keys(other), do: other
end
