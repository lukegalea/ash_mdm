# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.ContentHash do
  @moduledoc """
  SHA-256 over the canonical JSON of a version's content: a mapping's field
  rules, or a match rule set's rules and survivorship.

  Canonical = string keys at every depth, so two values that differ only in
  key order (or in atom vs string keys) hash equal. Structs (a `Decimal`
  weight, say) encode through Jason as they stand. The hash is the version
  identity: `ImportBatch` pins a mapping's at open, and a batch never re-maps
  mid-flight.
  """

  @spec hash!(term()) :: String.t()
  def hash!(field_rules) do
    :crypto.hash(:sha256, Jason.encode!(canonicalize(field_rules)))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(%_{} = struct), do: struct

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
    |> Map.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other
end
