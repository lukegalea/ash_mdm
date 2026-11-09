# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Validations.ValidSurvivorship do
  @moduledoc """
  Activation gate for MatchRuleSet: every declared survivorship strategy
  must be one of `AshMdm.Survivorship.strategies/0`. Unknown strategies
  are REFUSED — the same closed-vocabulary discipline as mapping ops
  (a typo like "most_recnt" must not silently merge with the default).
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    policy = Ash.Changeset.get_attribute(changeset, :survivorship) || %{}
    known = AshMdm.Survivorship.strategies()

    attrs = policy["attributes"] || %{}
    default = policy["default"]

    unknown =
      Enum.filter(Map.values(attrs), fn a ->
        s = a && a["strategy"]
        s != nil and s not in known
      end)
      |> Enum.map(& &1["strategy"])

    unknown =
      if default != nil and default not in known do
        [default | unknown]
      else
        unknown
      end

    case unknown do
      [] ->
        validate_origin_rank(policy)

      strategies ->
        {:error,
         field: :survivorship, message: "unknown survivorship strategies: #{inspect(strategies)}"}
    end
  end

  # `origin_rank` has no default order: which origin outranks which is the
  # tenant's declared policy, so a strategy naming no order is refused.
  defp validate_origin_rank(policy) do
    declared = policy["origin_rank"]
    known = Enum.map(AshMdm.Assertions.rankable_origin_kinds(), &to_string/1)

    cond do
      not uses_origin_rank?(policy) and is_nil(declared) ->
        :ok

      not (is_list(declared) and declared != []) ->
        {:error,
         field: :survivorship, message: "the origin_rank strategy needs an origin_rank list"}

      Enum.any?(declared, &(&1 not in known)) ->
        {:error,
         field: :survivorship,
         message: "unknown origin kinds in origin_rank: #{inspect(declared -- known)}"}

      true ->
        :ok
    end
  end

  defp uses_origin_rank?(policy) do
    policy["default"] == "origin_rank" or
      Enum.any?(Map.values(policy["attributes"] || %{}), &(&1["strategy"] == "origin_rank"))
  end
end
