# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Resolution do
  @moduledoc """
  Which declared resolver should close each gap. Pure: gaps (as returned by
  `AshMdm.Completeness.gaps/3`), the active resolvers and the attributes
  already held go in; one answer per gap comes out. Nothing runs, nothing is
  stored. Running a resolver and remembering the attempt belong to the host.

  A resolver is any map with `:name`, `:kind`, `:produces`, `:requires` and
  `:cost_rank` (the `:resolver` resource satisfies this). Kinds are closed:
  `human`, `inference`, `judgment`, `evidence`, `enrichment`.

  ## Selection

  Greedy and deterministic. For a gap, the usable resolver with the lowest
  `cost_rank` wins, ties broken by `name`. A resolver is usable when every
  attribute it requires is held, or was produced by a step planned in an
  earlier round. Rounds repeat until nothing more can be planned (a fixed
  point), so a chain resolves in order and a cycle never does: it ends in
  `needs_input`. Greedy means a gap takes the cheapest resolver usable in the
  round it is reached; the planner does not search for a globally cheapest
  plan.

  Only gaps are planned. A requirement that is not itself a gap is never
  chased, even when some resolver could produce it: the step comes back
  `needs_input` naming it. A step may start from whatever is passed as held,
  so leave out anything too old or too doubtful to build on.

  ## Origins

  A resolver that cannot close the gap is not a candidate, however cheap. When
  a gap carries `accepted_origins`, a resolver qualifies only if the statement
  that would end up standing has an accepted origin. That is the resolver's
  own kind, except on a material gap, where it is always a person's: the gap
  closes on the `human` statement admitting what the resolver produced, so a
  material gap qualifies every resolver if `human` is accepted and none if it
  is not. A gap repeated across purposes must satisfy each of them.

  ## Answers

  One map per distinct gap attribute, sorted by attribute, so the order of
  the inputs never changes the output:

    * `%{status: :planned, resolver: name, kind: kind, round: n,
      after: [attribute], needs_person: boolean}`. `after` lists attributes
      the step waits for that are not already held. `needs_person` is true
      when the gap is `material` and the chosen kind is not `human`: a person
      must admit what that resolver produces. The planner never decides that
      a person is unnecessary.
    * `%{status: :needs_input, resolver: name, missing: [attribute]}`: some
      resolver able to close the gap produces the attribute but none is usable.
      `resolver` is the one closest to usable, and `missing` is what it still
      requires.
    * `%{status: :no_route, because: string}`: no resolver produces it, or
      none that produces it can land an origin the gap accepts.
  """

  @kinds ~w(human inference judgment evidence enrichment)

  @doc "The closed vocabulary of resolver kinds."
  def kinds, do: @kinds

  @spec plan([map()], [map()], Enumerable.t()) :: [map()]
  def plan(gaps, resolvers, held) when is_list(gaps) and is_list(resolvers) do
    held = MapSet.new(held, &to_string/1)
    gaps = distinct_gaps(gaps)
    resolvers = Enum.sort_by(resolvers, &{&1.cost_rank, &1.name})

    {planned, available} = rounds(gaps, resolvers, held, held, %{}, 1)

    gaps
    |> Enum.map(fn gap ->
      case Map.fetch(planned, gap.attribute) do
        {:ok, step} -> Map.put(step, :attribute, gap.attribute)
        :error -> unplanned(gap, resolvers, available)
      end
    end)
  end

  defp distinct_gaps(gaps) do
    gaps
    |> Enum.group_by(&to_string(&1.attribute))
    |> Enum.map(fn {attribute, group} ->
      %{
        attribute: attribute,
        material: Enum.any?(group, &(Map.get(&1, :material) == true)),
        accepted: accepted(group)
      }
    end)
    |> Enum.sort_by(& &1.attribute)
  end

  defp accepted(group) do
    group
    |> Enum.map(&Map.get(&1, :accepted_origins))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn origins -> MapSet.new(origins, &to_string/1) end)
    |> case do
      [] -> nil
      [first | rest] -> Enum.reduce(rest, first, &MapSet.intersection/2)
    end
  end

  defp rounds(gaps, resolvers, held, available, planned, round) do
    open = Enum.reject(gaps, &Map.has_key?(planned, &1.attribute))

    steps =
      for gap <- open,
          resolver = Enum.find(resolvers, &usable?(&1, gap, available)),
          do: {gap, resolver}

    if steps == [] do
      {planned, available}
    else
      planned =
        Enum.reduce(steps, planned, fn {gap, resolver}, acc ->
          Map.put(acc, gap.attribute, step(gap, resolver, held, round))
        end)

      available =
        Enum.reduce(steps, available, fn {_gap, resolver}, acc ->
          MapSet.union(acc, MapSet.new(resolver.produces, &to_string/1))
        end)

      rounds(gaps, resolvers, held, available, planned, round + 1)
    end
  end

  defp usable?(resolver, gap, available),
    do: closes?(resolver, gap) and unmet(resolver, available) == []

  defp closes?(resolver, gap), do: produces?(resolver, gap.attribute) and accepts?(gap, resolver)

  defp accepts?(%{accepted: nil}, _resolver), do: true
  defp accepts?(%{material: true, accepted: accepted}, _resolver), do: "human" in accepted
  defp accepts?(%{accepted: accepted}, resolver), do: to_string(resolver.kind) in accepted

  defp produces?(resolver, attribute), do: attribute in Enum.map(resolver.produces, &to_string/1)

  defp unmet(resolver, available),
    do: resolver.requires |> Enum.map(&to_string/1) |> Enum.reject(&MapSet.member?(available, &1))

  defp step(gap, resolver, held, round) do
    kind = to_string(resolver.kind)

    %{
      status: :planned,
      resolver: resolver.name,
      kind: kind,
      round: round,
      after:
        resolver.requires
        |> Enum.map(&to_string/1)
        |> Enum.reject(&MapSet.member?(held, &1))
        |> Enum.sort(),
      needs_person: gap.material and kind != "human"
    }
  end

  defp unplanned(%{attribute: attribute} = gap, resolvers, available) do
    producers = Enum.filter(resolvers, &produces?(&1, attribute))

    case Enum.filter(producers, &closes?(&1, gap)) do
      [] when producers == [] ->
        no_route(attribute, "no active resolver produces this attribute")

      [] ->
        no_route(attribute, "no resolver producing this attribute can land an accepted origin")

      closers ->
        {resolver, missing} =
          closers
          |> Enum.map(&{&1, &1 |> unmet(available) |> Enum.sort()})
          |> Enum.min_by(fn {resolver, missing} ->
            {length(missing), resolver.cost_rank, resolver.name}
          end)

        %{attribute: attribute, status: :needs_input, resolver: resolver.name, missing: missing}
    end
  end

  defp no_route(attribute, because),
    do: %{attribute: attribute, status: :no_route, because: because}
end
