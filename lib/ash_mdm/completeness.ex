# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Completeness do
  @moduledoc """
  Whether a golden record has what a declared purpose needs. Pure: a profile's
  requirements and a golden's assertions go in, one answer per required
  attribute comes out.

  A requirement is string-keyed JSON, and a profile has one per attribute:

      %{"attribute" => "tax_id",
        "need" => "required",
        "because" => "Payment cannot be set up without it",
        "material" => true,
        "max_age_days" => 365,
        "accepted_origins" => ["human", "import"]}

  `need` is `required`, `optional` or `out_of_scope`. `because` is mandatory
  on all three. The rest is optional, and only meaningful when required:

    * `material`: the attribute moves money or creates liability, so a
      resolver must never admit it unattended. A host enforces this by banding
      such a statement `:review`.
    * `max_age_days`: older than this and the value is stale.
    * `accepted_origins`: origin kinds this purpose will rely on. A list and
      not a ranking, so a host never has to declare that one kind of origin
      is "stronger" than another in general.

  Kinds, worst first: `:missing`, `:origin_not_accepted`, `:expired`,
  `:stale`, and `:satisfied`.

  A requirement is judged against every competing statement holding the
  standing value, not only the fold's winner, and the best outcome stands. A
  tie goes to the statement that keeps that outcome longest, then the newest,
  and the assessment names that statement: a projected row re-judges only the
  statement it names, so naming one about to lapse would report a gap while
  another statement still holds the value. So a value later confirmed by an
  accepted origin, or by fresher evidence, is no longer a gap. A different
  value from an accepted origin changes nothing: it is not the standing value.
  """

  alias AshMdm.Assertions

  @needs ~w(required optional out_of_scope)
  @kinds [:missing, :origin_not_accepted, :expired, :stale, :satisfied]
  @best_first Enum.reverse(@kinds)
  @never DateTime.to_unix(~U[9999-12-31 23:59:59.999999Z], :microsecond)

  @doc "The closed vocabulary of what a requirement can need."
  def needs, do: @needs

  @doc "The closed vocabulary of assessment outcomes."
  def kinds, do: @kinds

  @doc """
  One entry per required attribute. Options: `:policy` (survivorship policy,
  default `%{}`), `:depths` (see `AshMdm.Assertions.chain_depths/2`), `:now`.
  """
  @spec assess([map()], [map()], keyword()) :: [map()]
  def assess(requirements, assertions, opts \\ []) when is_list(requirements) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    standing = Assertions.standing(Keyword.get(opts, :policy, %{}), assertions, opts)
    pending = assertions |> Assertions.pending() |> Enum.frequencies_by(& &1.attribute)

    requirements
    |> Enum.filter(&(&1["need"] == "required"))
    |> Enum.map(fn requirement ->
      attribute = requirement["attribute"]
      {kind, statement} = judge(requirement, Map.get(standing.supporting, attribute, []), now)

      %{
        attribute: attribute,
        kind: kind,
        because: requirement["because"],
        material: requirement["material"] == true,
        max_age_days: requirement["max_age_days"],
        accepted_origins: requirement["accepted_origins"],
        has_value: not is_nil(statement),
        standing_origin: statement && to_string(statement.origin_kind),
        observed_at: statement && statement.observed_at,
        valid_until: statement && Map.get(statement, :valid_until),
        assertion_id: statement && Map.get(statement, :id),
        pending_count: Map.get(pending, attribute, 0)
      }
    end)
  end

  @doc "`assess/3`, leaving out what is satisfied."
  @spec gaps([map()], [map()], keyword()) :: [map()]
  def gaps(requirements, assertions, opts \\ []) do
    requirements |> assess(assertions, opts) |> Enum.reject(&(&1.kind == :satisfied))
  end

  defp judge(_requirement, [], _now), do: {:missing, nil}

  # Supporting statements are newest first and `min_by` keeps the first of a
  # tie, so statements holding an outcome equally long go to the newest.
  defp judge(requirement, supporting, now) do
    supporting
    |> Enum.map(&{kind(requirement, &1, now), &1})
    |> Enum.min_by(fn {kind, statement} ->
      {Enum.find_index(@best_first, &(&1 == kind)), -holds_until(kind, requirement, statement)}
    end)
  end

  defp holds_until(:satisfied, requirement, statement) do
    earliest([Map.get(statement, :valid_until), stale_at(requirement, statement)])
  end

  defp holds_until(:stale, _requirement, statement) do
    earliest([Map.get(statement, :valid_until)])
  end

  defp holds_until(_kind, _requirement, _statement), do: @never

  defp stale_at(%{"max_age_days" => days}, statement) when is_integer(days) do
    DateTime.add(statement.observed_at, days, :day)
  end

  defp stale_at(_requirement, _statement), do: nil

  defp earliest(moments) do
    moments
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&DateTime.to_unix(&1, :microsecond))
    |> Enum.min(fn -> @never end)
  end

  defp kind(requirement, statement, now) do
    cond do
      not origin_accepted?(requirement["accepted_origins"], statement) -> :origin_not_accepted
      expired?(Map.get(statement, :valid_until), now) -> :expired
      stale?(requirement["max_age_days"], statement.observed_at, now) -> :stale
      true -> :satisfied
    end
  end

  defp origin_accepted?(nil, _statement), do: true
  defp origin_accepted?(accepted, statement), do: to_string(statement.origin_kind) in accepted

  defp expired?(nil, _now), do: false
  defp expired?(valid_until, now), do: DateTime.compare(valid_until, now) != :gt

  defp stale?(nil, _observed_at, _now), do: false

  defp stale?(days, observed_at, now),
    do: DateTime.compare(observed_at, DateTime.add(now, -days, :day)) == :lt
end
