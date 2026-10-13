# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.Validator do
  @moduledoc """
  The runtime validation set — the activate gate.

  Mirrors ash_strangler's compile-time verifiers as data checks. A mapping
  that cannot explain every target attribute of its `target_resource` is not
  valid, no matter how good the parts look: total accounting is the contract
  that makes replay deterministic and makes "what happened to this field" a
  question the mapping itself answers.

  Checks:

    1. **Unknown operator** — an op outside `AshMdm.Mapping.Evaluator.ops/0`.
    2. **Total accounting** — every public attribute of the target resource
       is mapped, constant, or explicitly `unmapped` **with a `because`**.
       An unexplained unmapped attribute is a validation error.
    3. **Decode totality + injectivity** — the value table covers every
       observed value of its path (`observed_schema`), and no two keys decode
       to the same target value; a counterexample is reported either way.
    4. **Required paths** — a rule marked `required` must have its path
       present in `observed_schema`, or the mapping cannot be trusted against
       the source it was proposed from.
    5. **Cast compatibility** — a `cast` op must name the target attribute's
       own type.
    6. **Egress read-only refusal** — a rule marked `read_only` is refused
       when the mapping's direction is `:egress` input (write-back shape).

  `findings/2` returns `%{errors: [...], warnings: [...]}`; a mapping is
  valid iff `errors == []`.
  """

  @spec findings(map(), keyword()) :: %{errors: [map()], warnings: [map()]}
  def findings(mapping, opts \\ []) do
    rules = decode_rules(mapping.field_rules)
    target = target_attributes(mapping.target_resource, opts)

    errors =
      [
        unknown_ops(rules),
        unaccounted_targets(rules, target),
        decode_problems(rules, mapping.observed_schema),
        missing_required_paths(rules, mapping.observed_schema),
        cast_mismatches(rules, target),
        egress_read_only(rules, mapping.direction)
      ]
      |> Enum.concat()

    %{errors: errors, warnings: []}
  end

  @doc "True iff the mapping would pass the activate gate."
  @spec valid?(map(), keyword()) :: boolean()
  def valid?(mapping, opts \\ []) do
    findings(mapping, opts).errors == []
  end

  defp decode_rules(%{"__struct__" => _}), do: []
  defp decode_rules(rules) when is_list(rules), do: rules
  defp decode_rules(_), do: []

  # ── 1. unknown operators ──────────────────────────────────────────────────

  defp unknown_ops(rules) do
    known = AshMdm.Mapping.Evaluator.ops()

    for rule <- rules,
        is_map(rule),
        op = rule["op"],
        op not in known do
      %{check: :unknown_op, op: op, target: rule["target"]}
    end
  end

  # ── 2. total accounting ───────────────────────────────────────────────────

  defp unaccounted_targets(rules, {:ok, target_attrs}) do
    accounted =
      rules
      |> Enum.filter(&is_map/1)
      |> Map.new(fn rule -> {rule["target"], rule} end)

    for %{name: name} <- target_attrs,
        finding = account_problem(Map.get(accounted, to_string(name)), name),
        finding != nil do
      finding
    end
  end

  defp account_problem(nil, name), do: %{check: :unaccounted_target, target: to_string(name)}

  defp account_problem(rule, name) do
    if rule["op"] == "unmapped" and blank?(rule["because"]) do
      %{check: :unmapped_without_because, target: to_string(name)}
    end
  end

  defp unaccounted_targets(_rules, :unknown_target), do: []
  defp unaccounted_targets(_rules, {:unknown_target, _}), do: []

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # ── 3. decode totality + injectivity ──────────────────────────────────────

  defp decode_problems(rules, observed_schema) do
    Enum.flat_map(rules, fn rule ->
      case rule do
        %{"op" => "decode", "args" => %{"table" => table}} = rule when is_map(table) ->
          decode_rule_problems(rule, table, observed_values(observed_schema, rule["path"]))

        %{"op" => "decode"} = rule ->
          [%{check: :missing_decode_table, target: rule["target"]}]

        _ ->
          []
      end
    end)
  end

  defp decode_rule_problems(rule, table, observed) do
    # Injectivity: two keys decoding to the same value.
    collisions =
      table
      |> Enum.group_by(fn {_k, v} -> to_string(v) end, fn {k, _} -> k end)
      |> Enum.filter(fn {_decoded, keys} -> length(keys) > 1 end)
      |> Enum.map(fn {decoded, keys} ->
        %{
          check: :decode_not_injective,
          decoded: decoded,
          keys: Enum.sort(keys),
          target: rule["target"]
        }
      end)

    # Totality against observed values, when the schema observed any.
    uncovered =
      case observed do
        values when is_list(values) and values != [] ->
          for v <- values,
              not Map.has_key?(table, to_string(v)) do
            %{check: :decode_not_total, value: v, path: rule["path"], target: rule["target"]}
          end

        _ ->
          []
      end

    collisions ++ uncovered
  end

  defp observed_values(schema, path) when is_map(schema) do
    case Map.get(schema, path) || Map.get(schema, path && String.to_existing_atom(path)) do
      %{"values" => values} -> values
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp observed_values(_schema, _path), do: nil

  # ── 4. required paths ─────────────────────────────────────────────────────

  defp missing_required_paths(rules, observed_schema) when is_map(observed_schema) do
    for rule <- rules,
        is_map(rule),
        rule["required"] == true,
        path = rule["path"],
        not path_observed?(observed_schema, path) do
      %{check: :required_path_not_observed, path: path, target: rule["target"]}
    end
  end

  defp missing_required_paths(_rules, _schema), do: []

  defp path_observed?(schema, path) when is_map(schema) do
    root =
      path
      |> to_string()
      |> String.split(".")
      |> List.first()

    Enum.any?(schema, fn {key, _} -> to_string(key) == root end)
  end

  # ── 5. cast compatibility ─────────────────────────────────────────────────

  defp cast_mismatches(rules, {:ok, target_attrs}) do
    for rule <- rules,
        is_map(rule),
        rule["op"] == "cast",
        attr = find_attr(target_attrs, rule["target"]),
        attr != nil,
        declared = rule["args"]["type"],
        declared != nil,
        to_string(declared) != to_string(attr.type) do
      %{check: :cast_type_mismatch, target: rule["target"], declared: declared, actual: attr.type}
    end
  end

  defp cast_mismatches(_rules, _target), do: []

  defp find_attr(attrs, target) do
    Enum.find(attrs, fn a ->
      to_string(a.name) == to_string(target)
    end)
  end

  # ── 6. egress read-only refusal ───────────────────────────────────────────

  defp egress_read_only(rules, direction) do
    if direction == :egress or direction == "egress" do
      for rule <- rules,
          is_map(rule),
          rule["read_only"] == true do
        %{check: :egress_read_only_rule, target: rule["target"]}
      end
    else
      []
    end
  end

  # ── target introspection ──────────────────────────────────────────────────

  defp target_attributes(name, opts) when is_binary(name) do
    case Module.concat([name]) |> Code.ensure_compiled() do
      {:module, mod} -> target_attributes(mod, opts)
      _ -> {:unknown_target, name}
    end
  end

  defp target_attributes(mod, _opts) when is_atom(mod) do
    if function_exported?(mod, :spark_dsl_config, 0) do
      attrs =
        mod
        |> Ash.Resource.Info.attributes()
        |> Enum.reject(&(&1.name in unaccountable()))
        |> Enum.map(&%{name: &1.name, type: &1.type})

      {:ok, attrs}
    else
      {:unknown_target, mod}
    end
  end

  # Framework-owned attributes a mapping never accounts for: identity,
  # tenancy, provenance and lifecycle columns are the base's business. The
  # CDM system-attribute set (Dataverse's) is included by name so hosts on
  # a platform base need no per-host opts.
  @unaccountable ~w(id organization_id inserted_at updated_at created_at version_id
    merged master_id
    created_on modified_on created_by_id modified_by_id created_on_behalf_by_id
    modified_on_behalf_by_id overridden_created_on import_sequence_number version_number
    state_code status_code lifecycle_status owning_business_unit_id
    owning_team_id owning_user_id owner_type owner_id)a

  defp unaccountable, do: @unaccountable
end
