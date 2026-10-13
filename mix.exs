# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lukegalea/ash_mdm"

  def project do
    [
      app: :ash_mdm,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: """
      Master data management machinery for Ash: versioned schema mappings as
      data, deterministic entity resolution with rules-as-data, survivorship
      and non-destructive merge over golden records. Resource macros in the
      ash_discrete_business_events style — the host instantiates them on its
      own platform base and keeps its own policies.
      """,
      source_url: @source_url,
      deps: deps(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # BIZEV-3/4 floors: temporal SourceRecord landing and the event ledger.
      {:ash, "~> 3.34"},
      {:ash_postgres, "~> 2.14"},
      {:ash_discrete_business_events, github: "lukegalea/ash_discrete_business_events"},
      {:spark, "~> 2.0"},
      {:jason, "~> 1.4"},
      # Required by Spark.Formatter, which formats the DSL blocks.
      {:sourceror, "~> 1.7", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      maintainers: ["Luke Galea"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE usage-rules.md CHANGELOG.md)
    ]
  end
end
