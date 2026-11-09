# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Assertions do
  @moduledoc """
  The fold over attribute assertions: which statement about each attribute
  of a golden record stands, and why. Pure; a host reads the rows, takes its
  own lock, calls `fold/3` and writes the result.

  An assertion is one statement that an attribute of a golden record has a
  value, with where that statement came from. Input order is part of the
  contract, because `non_null` is first non-nil in record order:

    1. merge-chain depth, the surviving golden first;
    2. `observed_at`, oldest first;
    3. id, so the order is total.

  So under the default policy the value a golden already holds keeps winning
  over one that arrives later, and a survivor's value wins over an absorbed
  record's.

  Statements that do not compete:

    * a retraction, and any statement a retraction names;
    * one banded `:review` or `:omit`: it waits for a person, or was refused;
    * a nil or blank value.

  An expired statement still competes. Expiry is a gap to close, not a reason
  to blank a value someone is relying on.

  A host may pass plain maps with the same keys for values it holds outside
  this table: they fold like any statement and are not persisted. `value` is
  always wrapped, see `wrap_value/1`.
  """

  alias AshMdm.Survivorship

  @origin_kinds [:import, :inference, :judgment, :evidence, :enrichment, :human, :retraction]

  @doc "The closed vocabulary of where a statement can come from."
  def origin_kinds, do: @origin_kinds

  @doc "The origin kinds a survivorship `origin_rank` may name."
  def rankable_origin_kinds, do: @origin_kinds -- [:retraction]

  @doc "A value as stored: JSON has no bare scalar column, so it rides in a map."
  def wrap_value(value), do: %{"v" => value}

  @doc "The value out of its stored wrapper."
  def unwrap_value(%{"v" => value}), do: value
  def unwrap_value(_), do: nil

  @doc """
  Folds assertions under a survivorship policy into
  `%{merged: map, provenance: map}`.

  Each provenance entry adds `"assertion_id"` and `"origin"` to what
  `AshMdm.Survivorship` records. Options:

    * `:depths`: `%{golden_id => depth}` from `chain_depths/2`. A golden not
      in the map is depth 0.
  """
  @spec fold(map(), [map()], keyword()) :: %{merged: map(), provenance: map()}
  def fold(policy, assertions, opts \\ []) when is_map(policy) and is_list(assertions) do
    policy |> standing(assertions, opts) |> Map.delete(:statements)
  end

  @doc """
  `fold/3`, plus `statements`: the assertion standing behind each attribute.
  """
  @spec standing(map(), [map()], keyword()) :: %{
          merged: map(),
          provenance: map(),
          statements: map()
        }
  def standing(policy, assertions, opts \\ []) when is_map(policy) and is_list(assertions) do
    depths = Keyword.get(opts, :depths, %{})

    case assertions |> competing() |> Enum.sort_by(&order_key(&1, depths)) |> records() do
      [] ->
        %{merged: %{}, provenance: %{}, statements: %{}}

      records ->
        %{merged: merged, provenance: provenance, winners: winners} =
          Survivorship.resolve_with_winners(policy, records)

        %{
          merged: merged,
          provenance: enrich_provenance(provenance, winners),
          statements: Map.new(winners, fn {key, winner} -> {key, winner.record[key]} end)
        }
    end
  end

  @doc "The statements waiting on a person: banded `:review` and not retracted."
  @spec pending([map()]) :: [map()]
  def pending(assertions) when is_list(assertions) do
    retracted = retracted_ids(assertions)

    Enum.filter(assertions, fn assertion ->
      Map.get(assertion, :band) == :review and
        not MapSet.member?(retracted, Map.get(assertion, :id))
    end)
  end

  @doc """
  Merge-chain depth of every golden that folds into `root`, given
  `{absorbed_id, master_id}` edges. The root is 0. A cycle in the edges ends
  the walk rather than looping: each id is visited once, at its shallowest.
  """
  @spec chain_depths(term(), [{term(), term()}]) :: %{term() => non_neg_integer()}
  def chain_depths(root, edges) when is_list(edges) do
    children = Enum.group_by(edges, &elem(&1, 1), &elem(&1, 0))
    walk([root], 0, %{}, children)
  end

  defp walk([], _depth, seen, _children), do: seen

  defp walk(level, depth, seen, children) do
    seen = Enum.reduce(level, seen, &Map.put_new(&2, &1, depth))

    next =
      level
      |> Enum.flat_map(&Map.get(children, &1, []))
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(seen, &1))

    walk(next, depth + 1, seen, children)
  end

  defp competing(assertions) do
    retracted = retracted_ids(assertions)

    Enum.filter(assertions, fn assertion ->
      assertion.origin_kind != :retraction and
        not MapSet.member?(retracted, Map.get(assertion, :id)) and
        Map.get(assertion, :band) in [nil, :admit] and
        not blank?(unwrap_value(assertion.value))
    end)
  end

  defp retracted_ids(assertions) do
    for %{origin_kind: :retraction, retracts_id: id} <- assertions, into: MapSet.new(), do: id
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp order_key(assertion, depths) do
    {Map.get(depths, Map.get(assertion, :golden_id), 0),
     DateTime.to_unix(assertion.observed_at, :microsecond), to_string(Map.get(assertion, :id))}
  end

  # One statement of origin becomes one record, however many attributes it
  # spoke to, so `most_complete` compares what each origin said as a whole.
  defp records(sorted) do
    groups = Enum.group_by(sorted, &group_key/1)

    sorted
    |> Enum.map(&group_key/1)
    |> Enum.uniq()
    |> Enum.map(&record(Map.fetch!(groups, &1)))
  end

  defp group_key(assertion) do
    {Map.get(assertion, :golden_id), assertion.origin_kind, assertion.source,
     Map.get(assertion, :origin_ref), assertion.observed_at}
  end

  defp record([first | _] = group) do
    {attributes, statements} =
      Enum.reduce(group, {%{}, %{}}, fn assertion, {values, statements} ->
        {Map.put_new(values, assertion.attribute, unwrap_value(assertion.value)),
         Map.put_new(statements, assertion.attribute, assertion)}
      end)

    %{
      record: statements,
      source: first.source,
      origin: first.origin_kind,
      observed_at: first.observed_at,
      attributes: attributes
    }
  end

  defp enrich_provenance(provenance, winners) do
    Map.new(provenance, fn {attribute, entry} ->
      case Map.get(winners, attribute) do
        nil ->
          {attribute, entry}

        winner ->
          {attribute,
           Map.merge(entry, %{
             "assertion_id" => Map.get(Map.fetch!(winner.record, attribute), :id),
             "origin" => to_string(winner.origin)
           })}
      end
    end)
  end
end
