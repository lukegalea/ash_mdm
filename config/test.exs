# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

if System.get_env("SKIP_DB") do
  config :ash_mdm, :db_tests_enabled?, false
else
  config :ash_mdm, :db_tests_enabled?, true
end

config :ash_mdm, AshMdm.Test.Repo,
  database: "ash_mdm_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  queue_target: 1000

config :ash, disable_async?: true

config :ash_mdm, :allowed_targets, %{
  "AshMdm.Fixtures.Person" => AshMdm.Fixtures.Person
}

config :logger, level: :warning
