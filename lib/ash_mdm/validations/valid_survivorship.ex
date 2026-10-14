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
        :ok

      strategies ->
        {:error,
         field: :survivorship,
         message: "unknown survivorship strategies: #{inspect(strategies)}"}
    end
  end
end
