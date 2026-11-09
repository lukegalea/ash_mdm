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
    :crypto.hash(:sha256, canonical_json(field_rules))
    |> Base.encode16(case: :lower)
  end

  @doc """
  HMAC-SHA256 over the same canonical JSON, keyed by `secret`, for content
  whose values are low-entropy enough that an unkeyed hash can be brute-forced.
  """
  @spec hmac!(term(), binary()) :: String.t()
  def hmac!(content, secret) when is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, canonical_json(content))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(content), do: Jason.encode!(canonicalize(content))

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
