# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.EgressValidatorTest do
  @moduledoc """
  The validator reads an egress mapping backwards: the PATH names the golden
  attribute (what must be accounted), the TARGET names the customer's field
  (checked against their declared shape). Renamed fields validate; an
  unmapped golden attribute or a target outside the declared shape refuses.
  """

  use ExUnit.Case, async: true

  alias AshMdm.Mapping.Validator

  @target "AshMdm.Fixtures.Person"

  test "renamed customer fields validate when paths account the golden" do
    findings =
      Validator.findings(%{
        direction: :egress,
        target_resource: @target,
        observed_schema: %{"Email Address" => %{}, "Customer Name" => %{}},
        field_rules: [
          %{"path" => "email", "target" => "Email Address", "op" => "identity", "args" => %{}},
          %{"path" => "name", "target" => "Customer Name", "op" => "identity", "args" => %{}},
          %{
            "path" => nil,
            "target" => "tier",
            "op" => "unmapped",
            "args" => %{},
            "because" => "internal grading"
          },
          %{
            "path" => nil,
            "target" => "joined_on",
            "op" => "unmapped",
            "args" => %{},
            "because" => "internal metadata"
          }
        ]
      })

    assert findings.errors == []
  end

  test "an unmapped golden attribute is refused on egress too" do
    findings =
      Validator.findings(%{
        direction: :egress,
        target_resource: @target,
        observed_schema: %{"Customer Name" => %{}},
        field_rules: [
          %{"path" => "name", "target" => "Customer Name", "op" => "identity", "args" => %{}},
          %{
            "path" => nil,
            "target" => "tier",
            "op" => "unmapped",
            "args" => %{},
            "because" => "internal grading"
          },
          %{
            "path" => nil,
            "target" => "joined_on",
            "op" => "unmapped",
            "args" => %{},
            "because" => "internal metadata"
          }
        ]
      })

    assert Enum.any?(findings.errors, &(&1.check == :unaccounted_target and &1.target == "email"))
  end

  test "a target outside the customer's declared shape is refused" do
    findings =
      Validator.findings(%{
        direction: :egress,
        target_resource: @target,
        observed_schema: %{"Customer Name" => %{}},
        field_rules: [
          %{"path" => "email", "target" => "Not Declared", "op" => "identity", "args" => %{}},
          %{"path" => "name", "target" => "Customer Name", "op" => "identity", "args" => %{}},
          %{
            "path" => nil,
            "target" => "tier",
            "op" => "unmapped",
            "args" => %{},
            "because" => "internal grading"
          },
          %{
            "path" => nil,
            "target" => "joined_on",
            "op" => "unmapped",
            "args" => %{},
            "because" => "internal metadata"
          }
        ]
      })

    assert Enum.any?(findings.errors, &(&1.check == :unknown_egress_target))
  end
end
