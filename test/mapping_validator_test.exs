# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.ValidatorTest do
  @moduledoc "The validator set — rejects incomplete accounting, non-injective decode, unknown ops."

  use ExUnit.Case, async: true

  alias AshMdm.Mapping.Validator

  # AshMdm.Fixtures.Person contributes name/email/tier/joined_on.
  @target "AshMdm.Fixtures.Person"

  test "a complete mapping has no findings" do
    mapping = %{
      direction: :ingress,
      target_resource: @target,
      observed_schema: %{"Email" => %{"type" => "string"}, "Full Name" => %{"type" => "string"}},
      field_rules: [
        %{
          "path" => "Email",
          "target" => "email",
          "op" => "trim",
          "args" => %{},
          "required" => true
        },
        %{"path" => "Full Name", "target" => "name", "op" => "identity", "args" => %{}},
        %{
          "path" => "Since",
          "target" => "joined_on",
          "op" => "parse_date",
          "args" => %{},
          "required" => false
        },
        %{
          "path" => nil,
          "target" => "tier",
          "op" => "constant",
          "args" => %{"value" => "bronze"}
        },
        %{
          "path" => nil,
          "target" => "unknown_attr",
          "op" => "unmapped",
          "args" => %{},
          "because" => "source never carries it"
        }
      ]
    }

    assert Validator.valid?(mapping)
  end

  test "an unmapped target attribute without a because is an error" do
    mapping = %{
      direction: :ingress,
      target_resource: @target,
      observed_schema: %{"Email" => %{}},
      field_rules: [
        %{"path" => "Email", "target" => "email", "op" => "identity", "args" => %{}}
      ]
    }

    refute Validator.valid?(mapping)

    assert %{check: :unaccounted_target, target: "name"} in Validator.findings(mapping).errors
  end

  test "an unmapped rule without a because is an error" do
    mapping = %{
      direction: :ingress,
      target_resource: @target,
      observed_schema: %{"Email" => %{}},
      field_rules: [
        %{"path" => "Email", "target" => "email", "op" => "identity", "args" => %{}},
        %{"path" => nil, "target" => "name", "op" => "unmapped", "args" => %{}},
        %{
          "path" => nil,
          "target" => "tier",
          "op" => "unmapped",
          "args" => %{},
          "because" => "not carried"
        },
        %{
          "path" => nil,
          "target" => "joined_on",
          "op" => "unmapped",
          "args" => %{},
          "because" => "not carried"
        }
      ]
    }

    assert %{check: :unmapped_without_because, target: "name"} in Validator.findings(mapping).errors
  end

  test "unknown op is rejected" do
    mapping = %{
      direction: :ingress,
      target_resource: @target,
      observed_schema: %{},
      field_rules: [
        %{"path" => "Email", "target" => "email", "op" => "eval", "args" => %{}},
        %{"path" => nil, "target" => "name", "op" => "unmapped", "args" => %{}, "because" => "x"},
        %{"path" => nil, "target" => "tier", "op" => "unmapped", "args" => %{}, "because" => "x"},
        %{
          "path" => nil,
          "target" => "joined_on",
          "op" => "unmapped",
          "args" => %{},
          "because" => "x"
        }
      ]
    }

    assert Enum.any?(
             Validator.findings(mapping).errors,
             &(&1.check == :unknown_op and &1.op == "eval")
           )
  end

  test "non-injective decode reports the colliding keys" do
    mapping = %{
      direction: :ingress,
      target_resource: @target,
      observed_schema: %{"Tier" => %{"values" => ["P", "S", "X"]}},
      field_rules: [
        %{"path" => "Email", "target" => "email", "op" => "identity", "args" => %{}},
        %{
          "path" => "Tier",
          "target" => "tier",
          "op" => "decode",
          "args" => %{"table" => %{"P" => "premium", "S" => "premium", "X" => "standard"}}
        },
        %{"path" => nil, "target" => "name", "op" => "unmapped", "args" => %{}, "because" => "x"},
        %{
          "path" => nil,
          "target" => "joined_on",
          "op" => "unmapped",
          "args" => %{},
          "because" => "x"
        }
      ]
    }

    findings = Validator.findings(mapping).errors

    assert Enum.any?(
             findings,
             &(&1.check == :decode_not_injective and &1.decoded == "premium" and
                 &1.keys == ["P", "S"])
           )
  end

  test "decode totality is checked against observed values" do
    mapping = %{
      direction: :ingress,
      target_resource: @target,
      observed_schema: %{"Tier" => %{"values" => ["P", "Q"]}},
      field_rules: [
        %{"path" => "Email", "target" => "email", "op" => "identity", "args" => %{}},
        %{
          "path" => "Tier",
          "target" => "tier",
          "op" => "decode",
          "args" => %{"table" => %{"P" => "premium"}}
        },
        %{"path" => nil, "target" => "name", "op" => "unmapped", "args" => %{}, "because" => "x"},
        %{
          "path" => nil,
          "target" => "joined_on",
          "op" => "unmapped",
          "args" => %{},
          "because" => "x"
        }
      ]
    }

    assert Enum.any?(
             Validator.findings(mapping).errors,
             &(&1.check == :decode_not_total and &1.value == "Q")
           )
  end

  test "a required rule whose path the schema never observed is an error" do
    mapping = %{
      direction: :ingress,
      target_resource: @target,
      observed_schema: %{"Full Name" => %{}},
      field_rules: [
        %{
          "path" => "Email",
          "target" => "email",
          "op" => "identity",
          "args" => %{},
          "required" => true
        },
        %{"path" => "Full Name", "target" => "name", "op" => "identity", "args" => %{}},
        %{"path" => nil, "target" => "tier", "op" => "unmapped", "args" => %{}, "because" => "x"},
        %{
          "path" => nil,
          "target" => "joined_on",
          "op" => "unmapped",
          "args" => %{},
          "because" => "x"
        }
      ]
    }

    assert Enum.any?(
             Validator.findings(mapping).errors,
             &(&1.check == :required_path_not_observed and &1.path == "Email")
           )
  end

  test "cast must declare the target's own type" do
    mapping = %{
      direction: :ingress,
      target_resource: @target,
      observed_schema: %{"Since" => %{}},
      field_rules: [
        %{
          "path" => "Since",
          "target" => "joined_on",
          "op" => "cast",
          "args" => %{"type" => "integer"}
        },
        %{
          "path" => nil,
          "target" => "email",
          "op" => "unmapped",
          "args" => %{},
          "because" => "x"
        },
        %{"path" => nil, "target" => "name", "op" => "unmapped", "args" => %{}, "because" => "x"},
        %{"path" => nil, "target" => "tier", "op" => "unmapped", "args" => %{}, "because" => "x"}
      ]
    }

    assert %{check: :cast_type_mismatch, declared: "integer", actual: Ash.Type.Date} =
             Enum.find(Validator.findings(mapping).errors, &(&1.check == :cast_type_mismatch))
  end

  test "egress refuses read_only rules" do
    mapping = %{
      direction: :egress,
      target_resource: @target,
      observed_schema: %{"Email" => %{}},
      field_rules: [
        %{
          "path" => "email",
          "target" => "email",
          "op" => "identity",
          "args" => %{},
          "read_only" => true
        },
        %{"path" => nil, "target" => "name", "op" => "unmapped", "args" => %{}, "because" => "x"},
        %{"path" => nil, "target" => "tier", "op" => "unmapped", "args" => %{}, "because" => "x"},
        %{
          "path" => nil,
          "target" => "joined_on",
          "op" => "unmapped",
          "args" => %{},
          "because" => "x"
        }
      ]
    }

    assert Enum.any?(
             Validator.findings(mapping).errors,
             &(&1.check == :egress_read_only_rule and &1.target == "email")
           )
  end

  test "an unresolvable target resource skips accounting (documented escape, not a pass-through)" do
    mapping = %{
      direction: :ingress,
      target_resource: "NoSuch.Module",
      observed_schema: %{},
      field_rules: [%{"path" => "a", "target" => "a", "op" => "eval", "args" => %{}}]
    }

    # unknown-op still fires; accounting silently skips (the module can't be
    # introspected) — the resource allowlist is the host policy's job.
    findings = Validator.findings(mapping)
    assert Enum.any?(findings.errors, &(&1.check == :unknown_op))
    refute Enum.any?(findings.errors, &(&1.check == :unaccounted_target))
  end
end
