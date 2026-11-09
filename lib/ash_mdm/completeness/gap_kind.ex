# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Completeness.GapKind do
  @moduledoc """
  Whether a projected requirement is met, as of now, in the database. The
  same order as `AshMdm.Completeness.assess/3`, so a board can filter and
  count by it and nothing has to run to make a value go stale.
  """

  use Ash.Resource.Calculation

  @impl true
  def expression(_opts, _context) do
    Ash.Expr.expr(
      cond do
        not has_value ->
          :missing

        not is_nil(accepted_origins) and
            not fragment("? = ANY(?)", standing_origin, accepted_origins) ->
          :origin_not_accepted

        not is_nil(valid_until) and valid_until <= now() ->
          :expired

        not is_nil(max_age_days) and
            observed_at < fragment("now() - make_interval(days => ?::int)", max_age_days) ->
          :stale

        true ->
          :satisfied
      end
    )
  end
end
