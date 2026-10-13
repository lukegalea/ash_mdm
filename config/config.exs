# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

config :ash_mdm, ecto_repos: [AshMdm.Test.Repo]
config :ash_mdm, ash_domains: [AshMdm.Fixtures]

config :ash, default_string_length_count: :codepoints

config :ash_mdm, AshMdm.Test.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST") || System.get_env("PGHOST") || "localhost",
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  priv: "priv/test_repo"

if config_env() == :test do
  import_config "test.exs"
end
