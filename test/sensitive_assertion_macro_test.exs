# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.SensitiveAssertionMacroTest do
  @moduledoc "A sensitive attribute assertion must be given a digest secret."

  use ExUnit.Case, async: true

  defp compile(options) do
    name = "AshMdm.SensitiveAssertionMacroTest.Host#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use Ash.Resource,
        domain: AshMdm.Fixtures,
        data_layer: AshPostgres.DataLayer,
        validate_domain_inclusion?: false

      use AshMdm.Resources,
          {:attribute_assertion, [repo: AshMdm.Test.Repo, table: "unused"#{options}]}
    end
    """)
  end

  test "sensitive_value?: true with no digest_secret is refused at compile time" do
    assert_raise ArgumentError, ~r/digest_secret/, fn -> compile(", sensitive_value?: true") end
  end

  test "a digest_secret that isn't an MFA is refused at compile time" do
    assert_raise ArgumentError, ~r/digest_secret/, fn ->
      compile(~S|, sensitive_value?: true, digest_secret: "a-literal-key"|)
    end
  end
end
