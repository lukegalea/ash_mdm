# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.Diff do
  @moduledoc """
  What changed between two versions of a schema mapping, by what they do.

  Two mappings (rows of a `{:mapping, …}` resource, or maps with the same fields) are
  compared over what decides the records they produce:

    * **target**: the direction, source, stream and resource the mapping writes;
    * **fields**: each field rule by the field it writes (`target`), added or removed,
      and for one in both, each property that changed: its source `path`, its `op`, the
      operator's `args`, whether it is `required`, and the `because` of an `unmapped`
      rule.

  Rule order is not compared: rules do not chain, so their order changes nothing a
  record becomes (`AshMdm.Mapping.Evaluator`). Two rules that write the same field are
  told apart by their place among that field's rules (`"email"`, then `"email (2)"`).
  The observed schema, the validation findings and the lifecycle (`status`, `version`,
  the chain) are not compared.

  The result is a list of plain maps, one per change, with no struct, so a host can
  render or store it without depending on a type from this package:

      %{
        aspect: :fields,                  # one of aspects/0
        kind: :added | :removed | :changed,
        subject: "email",                 # the field, or the target property
        option: "path" | nil,             # for :changed, the property that changed
        from: term(), to: term()          # the old and new value, as plain data
      }

  An empty list means nothing this compares changed. It does not mean the two versions
  are identical; compare `content_hash` for the field rules.
  """

  @typedoc "One change between two versions."
  @type change :: %{
          aspect: atom(),
          kind: :added | :removed | :changed,
          subject: String.t() | nil,
          option: String.t() | nil,
          from: term(),
          to: term()
        }

  @doc """
  What `diff/2` compares, in the order a reader should see it, each with an English label.
  A host translates the labels in its own catalogue.
  """
  @spec aspects() :: [{atom(), String.t()}]
  def aspects do
    [
      target: "Target",
      fields: "Fields"
    ]
  end

  @doc "The changes from `old` to `new`, two mapping versions (or maps with their fields)."
  @spec diff(map(), map()) :: [change()]
  def diff(old, new) do
    keyed(:target, target(old), target(new)) ++
      keyed(:fields, fields(old), fields(new))
  end

  defp target(mapping) do
    %{
      "direction" => Map.get(mapping, :direction),
      "source" => Map.get(mapping, :source),
      "stream" => Map.get(mapping, :stream),
      "resource" => Map.get(mapping, :target_resource)
    }
  end

  # Each rule keyed by the field it writes. A second rule for the same field is keyed by
  # its place among that field's rules, so neither hides the other.
  defp fields(mapping) do
    mapping
    |> Map.get(:field_rules)
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(&to_string(&1["target"]))
    |> Enum.flat_map(fn {target, rules} ->
      rules
      |> Enum.with_index(1)
      |> Enum.map(fn
        {rule, 1} -> {target, Map.delete(rule, "target")}
        {rule, n} -> {"#{target} (#{n})", Map.delete(rule, "target")}
      end)
    end)
    |> Map.new()
  end

  # The changes between two maps of named subjects under `aspect`: added and removed names,
  # and, for a name in both, each property whose value differs. Values that are maps are
  # compared property by property; any other value is compared whole. The target aspect is
  # one map of properties, so each of its names is a property compared whole.
  defp keyed(aspect, old, new) do
    names = old |> Map.keys() |> Kernel.++(Map.keys(new)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(names, fn name ->
      case {Map.fetch(old, name), Map.fetch(new, name)} do
        {:error, {:ok, value}} -> [change(aspect, :added, name, nil, nil, value)]
        {{:ok, value}, :error} -> [change(aspect, :removed, name, nil, value, nil)]
        {{:ok, same}, {:ok, same}} -> []
        {{:ok, from}, {:ok, to}} -> properties(aspect, name, from, to)
      end
    end)
  end

  defp properties(aspect, name, %{} = from, %{} = to) do
    from
    |> Map.keys()
    |> Kernel.++(Map.keys(to))
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
    |> Enum.flat_map(fn option ->
      case {Map.get(from, option), Map.get(to, option)} do
        {same, same} -> []
        {old, new} -> [change(aspect, :changed, name, option, old, new)]
      end
    end)
  end

  defp properties(aspect, name, from, to), do: [change(aspect, :changed, name, nil, from, to)]

  defp change(aspect, kind, subject, option, from, to) do
    %{
      aspect: aspect,
      kind: kind,
      subject: subject && to_string(subject),
      option: option && to_string(option),
      from: from,
      to: to
    }
  end
end
