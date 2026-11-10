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
    2. within a depth, `:human` statements before all others;
    3. with the `:incumbent` option, the statement the golden already holds,
       before any other;
    4. `observed_at`, oldest first;
    5. id, so the order is total.

  So under the default policy a person's statement beats any import, the value
  a golden already holds keeps winning over what another source says later,
  and a survivor's value wins over an absorbed record's, even a person's.
  A `steward_override` policy resolves to the human statement for the same
  reason, and its provenance names that statement.

  ## Incumbent

  By default the order is by `observed_at` alone, so history imported late
  and dated before the value a golden holds replaces that value. A host that
  materializes the held value as a statement passes `incumbent: fun`, a
  one-arity function that returns true for exactly that statement, and the
  held value then outranks other sources however old their evidence is. A
  person still beats it, and depth still comes first: a survivor's statement
  beats an absorbed golden's incumbent. Mark only the materialized held
  value, never every statement of a source. The same option serves a host
  that reads values from a legacy row it has not migrated.

  The option reorders competitors, nothing else. `most_recent` still picks
  the latest `observed_at` and `most_complete` the highest completeness, so
  the incumbent only decides ties there, as the first record in order does.
  `pending/1` and the retraction walk never order competitors, so they are
  unaffected. Without the option nothing changes.

  A source speaks for itself once: on each golden and attribute, only the
  newest statement from one origin kind and source competes. That is what
  makes a correction work, and a refreshed import. Retracting the newest
  statement brings back the one before it. "Newest" is the latest
  `observed_at`, then the latest `inserted_at` when the statement has one, so
  a re-mapped correction carrying the same `observed_at` still wins.

  Each record carries a `completeness`: how many attributes its speaker
  (origin kind and source, on that golden) currently holds, so `most_complete`
  doesn't flip when a correction splits a source's statements across records.

  Statements that do not compete:

    * a retraction, and any statement an effective retraction names;
    * one banded `:review` or `:omit`: it waits for a person, or was refused;
    * a nil or blank value.

  Only a retraction banded nil or `:admit` takes effect. Retracting a
  retraction restores its target: retractions are walked newest first and one
  that has itself been withdrawn is skipped. The walk's order is total, so a
  chain or a cycle always folds the same. It trusts that order, so a
  retraction of a retraction must carry a later `observed_at` than the one it
  withdraws; written back-dated, it takes no effect on that retraction's
  target.

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
    * `:incumbent`: a one-arity function, true for a statement that is the
      golden's held value. It ranks after `:human` and before the oldest-first
      order. A non-function raises `ArgumentError`.
  """
  @spec fold(map(), [map()], keyword()) :: %{merged: map(), provenance: map()}
  def fold(policy, assertions, opts \\ []) when is_map(policy) and is_list(assertions) do
    policy |> standing(assertions, opts) |> Map.drop([:statements, :supporting])
  end

  @doc """
  `fold/3`, plus `statements`: the assertion standing behind each attribute,
  and `supporting`: for each attribute, every competing statement holding the
  standing value, winner included, newest first.
  """
  @spec standing(map(), [map()], keyword()) :: %{
          merged: map(),
          provenance: map(),
          statements: map(),
          supporting: map()
        }
  def standing(policy, assertions, opts \\ []) when is_map(policy) and is_list(assertions) do
    depths = Keyword.get(opts, :depths, %{})
    incumbent = incumbent!(opts)

    statements = assertions |> competing() |> latest_per_source()

    case statements |> Enum.sort_by(&order_key(&1, depths, incumbent)) |> records(incumbent) do
      [] ->
        %{merged: %{}, provenance: %{}, statements: %{}, supporting: %{}}

      records ->
        %{merged: merged, provenance: provenance, winners: winners} =
          Survivorship.resolve_with_winners(policy, records)

        %{
          merged: merged,
          provenance: enrich_provenance(provenance, winners),
          statements: Map.new(winners, fn {key, winner} -> {key, winner.record[key]} end),
          supporting: supporting(statements, merged)
        }
    end
  end

  @doc """
  The statements waiting on a person: banded `:review`, not retracted, and not
  superseded. A source speaks for itself once, so a newer statement from the
  same origin kind and source, on that golden and attribute, supersedes a
  review; one that was omitted or retracted does not. A retraction waiting on
  a person is never superseded: each one names its own target.

  Admitting a statement must be able to change something, so a blank value
  is never pending, and neither is a retraction whose target is already
  withdrawn.
  """
  @spec pending([map()]) :: [map()]
  def pending(assertions) when is_list(assertions) do
    withdrawn = withdrawn_ids(assertions)

    newest =
      assertions
      |> Enum.filter(&(speaks?(&1, withdrawn) and Map.get(&1, :band) != :omit))
      |> Enum.group_by(&speaker/1, &recency/1)
      |> Map.new(fn {speaker, recencies} -> {speaker, Enum.max(recencies)} end)

    Enum.filter(assertions, fn assertion ->
      Map.get(assertion, :band) == :review and
        not MapSet.member?(withdrawn, Map.get(assertion, :id)) and
        can_take_effect?(assertion, withdrawn) and
        not superseded?(assertion, newest)
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
    withdrawn = withdrawn_ids(assertions)

    Enum.filter(assertions, &(speaks?(&1, withdrawn) and Map.get(&1, :band) in [nil, :admit]))
  end

  defp speaks?(assertion, withdrawn) do
    assertion.origin_kind != :retraction and
      not MapSet.member?(withdrawn, Map.get(assertion, :id)) and
      not blank?(unwrap_value(assertion.value))
  end

  defp latest_per_source(assertions) do
    assertions
    |> Enum.group_by(&speaker/1)
    |> Enum.map(fn {_speaker, statements} -> Enum.max_by(statements, &recency/1) end)
  end

  defp speaker(assertion), do: {holder(assertion), assertion.attribute}

  defp holder(assertion) do
    {Map.get(assertion, :golden_id), assertion.origin_kind, assertion.source}
  end

  defp can_take_effect?(%{origin_kind: :retraction} = retraction, withdrawn) do
    not MapSet.member?(withdrawn, Map.get(retraction, :retracts_id))
  end

  defp can_take_effect?(assertion, _withdrawn), do: not blank?(unwrap_value(assertion.value))

  defp superseded?(%{origin_kind: :retraction}, _newest), do: false

  defp superseded?(assertion, newest) do
    case Map.fetch(newest, speaker(assertion)) do
      {:ok, latest} -> recency(assertion) < latest
      :error -> false
    end
  end

  defp recency(assertion) do
    {micros(assertion.observed_at), micros(Map.get(assertion, :inserted_at)),
     to_string(Map.get(assertion, :id))}
  end

  defp micros(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp micros(_), do: 0

  # Newest first, so a retraction that has itself been withdrawn is skipped
  # before it can withdraw anything.
  defp withdrawn_ids(assertions) do
    assertions
    |> Enum.filter(&(&1.origin_kind == :retraction and Map.get(&1, :band) in [nil, :admit]))
    |> Enum.sort_by(&recency/1, :desc)
    |> Enum.reduce(MapSet.new(), fn retraction, withdrawn ->
      if MapSet.member?(withdrawn, Map.get(retraction, :id)),
        do: withdrawn,
        else: MapSet.put(withdrawn, Map.get(retraction, :retracts_id))
    end)
  end

  defp supporting(statements, merged) do
    statements
    |> Enum.filter(&(Map.fetch(merged, &1.attribute) == {:ok, unwrap_value(&1.value)}))
    |> Enum.sort_by(&recency/1, :desc)
    |> Enum.group_by(& &1.attribute)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp incumbent!(opts) do
    case Keyword.get(opts, :incumbent) do
      nil ->
        fn _assertion -> false end

      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError, ":incumbent must be a one-arity function, got: #{inspect(other)}"
    end
  end

  defp order_key(assertion, depths, incumbent) do
    {Map.get(depths, Map.get(assertion, :golden_id), 0), person_rank(assertion),
     incumbent_rank(assertion, incumbent), micros(assertion.observed_at),
     to_string(Map.get(assertion, :id))}
  end

  defp person_rank(%{origin_kind: :human}), do: 0
  defp person_rank(_assertion), do: 1

  defp incumbent_rank(assertion, incumbent), do: if(incumbent.(assertion) == true, do: 0, else: 1)

  # One statement of origin becomes one record, however many attributes it
  # spoke to; `completeness` lets `most_complete` compare what each speaker
  # currently holds as a whole, however a correction has split it.
  defp records(sorted, incumbent) do
    group_key = &{group_key(&1), incumbent_rank(&1, incumbent)}
    groups = Enum.group_by(sorted, group_key)
    held = Enum.frequencies_by(sorted, &holder/1)

    sorted
    |> Enum.map(group_key)
    |> Enum.uniq()
    |> Enum.map(&record(Map.fetch!(groups, &1), held))
  end

  defp group_key(assertion) do
    {Map.get(assertion, :golden_id), assertion.origin_kind, assertion.source,
     Map.get(assertion, :origin_ref), assertion.observed_at}
  end

  defp record([first | _] = group, held) do
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
      attributes: attributes,
      completeness: Map.fetch!(held, holder(first))
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
