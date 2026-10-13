# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# The fixture host and the macro-generated resources are the package under
# test; make sure everything is loaded before any test runs.
[
  AshMdm.Fixtures,
  AshMdm.Fixtures.Mapping,
  AshMdm.Fixtures.Person,
  AshMdm.Fixtures.MatchRuleSet,
  AshMdm.Fixtures.MatchCandidate,
  AshMdm.Test.Repo
]
|> Enum.each(&Code.ensure_loaded!/1)

# The database is created and migrated here, once per test run, so a fresh
# clone needs no setup task; `SKIP_DB=1` excludes the `:db`-tagged tests.
# Order matters: storage_up runs BEFORE the repo starts (the bizev drill).
db_tests? =
  if Application.get_env(:ash_mdm, :db_tests_enabled?, true) do
    case AshMdm.Test.Repo.__adapter__().storage_up(AshMdm.Test.Repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    {:ok, _} = AshMdm.Test.Repo.start_link()

    Ecto.Adapters.SQL.Sandbox.mode(AshMdm.Test.Repo, :auto)

    Ecto.Migrator.run(AshMdm.Test.Repo, "priv/test_repo/migrations", :up, all: true)

    Ecto.Adapters.SQL.Sandbox.mode(AshMdm.Test.Repo, :manual)
    true
  else
    false
  end

ExUnit.start()

ExUnit.configure(exclude: if(db_tests?, do: [], else: [:db]))

unless db_tests? do
  IO.puts("note: SKIP_DB — excluding the database tests (:db tag)")
end
