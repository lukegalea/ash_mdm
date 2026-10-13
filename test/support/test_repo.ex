# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo do
  @moduledoc """
  The PostgreSQL repo behind the SUITE's fixture resources — the package's
  real resources ride the HOST's repo by construction; this one exists so
  the suite can instantiate its fixtures on a real database (the bizev
  drill). Migrations live in `priv/test_repo`; the test helper creates and
  migrates the database itself.
  """

  use AshPostgres.Repo,
    otp_app: :ash_mdm,
    warn_on_missing_ash_functions?: false

  def installed_extensions, do: ["uuid-ossp", "ash-functions"]

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
