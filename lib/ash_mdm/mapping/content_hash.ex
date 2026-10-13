# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.ContentHash do
  @moduledoc """
  SHA-256 over the canonical JSON of the field rules.

  Canonical = maps encoded with sorted keys, so two rules that differ only in
  key order hash equal. The hash is the version identity: `ImportBatch` pins
  it at open, and a batch never re-maps mid-flight.
  """

  @spec hash!(term()) :: String.t()
  def hash!(field_rules) do
    :crypto.hash(:sha256, Jason.encode!(canonicalize(field_rules)))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
    |> Map.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other
end
