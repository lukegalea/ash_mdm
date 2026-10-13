# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.Evaluator do
  @moduledoc """
  The pure fold that applies a mapping's field rules to one source payload.

  The operator vocabulary is **closed** — this module's `@ops` is the whole
  language. There is no eval, no quoted Elixir, no host callback except the
  optional `:ref_resolver` for `ref_lookup`. An unknown operator is an error,
  never a fallback: the validator refuses it earlier, and a payload that
  reaches this function with one has bypassed validation.

  Field rules are string-keyed maps (they are stored as JSON):

      %{"path" => "Email Address", "target" => "email", "op" => "trim",
        "args" => %{}, "required" => true}

  `path` is a dot-path into the payload. A `[]` segment (`Contacts[].Email`)
  descends into a list and takes its **first** element — deterministic, and
  the right default for "the primary contact" shape; multi-row expansion is
  not a per-record fold and stays out of v1.

  Returns `{:ok, %{target => value}}` with only the rules that produced a
  value, or `{:error, {:rule, rule, reason}}` naming the offending rule.

  **Semantics:** each rule reads its `path` from the *source payload* and
  writes one target. Rules do not chain — a rule cannot consume another
  rule's output. Composition beyond one operator means a new operator
  (a package change with a validator and tests), which is exactly the
  discipline the closed vocabulary is for.
  """

  @ops ~w(identity cast trim case parse_date parse_decimal decode concat coalesce constant regex_extract ref_lookup uuid_v5 unmapped)

  def ops, do: @ops

  @spec run([map()], map(), keyword()) ::
          {:ok, %{(atom() | binary()) => term()}} | {:error, {:rule, map(), term()}}
  def run(field_rules, payload, opts \\ []) when is_list(field_rules) do
    Enum.reduce_while(field_rules, {:ok, %{}}, fn rule, {:ok, acc} ->
      case apply_rule(rule, payload, opts) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, :unmapped} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, rule_target(rule), value)}}
        {:error, reason} -> {:halt, {:error, {:rule, rule, reason}}}
      end
    end)
  end

  defp rule_target(%{"target" => t}), do: to_string(t)

  defp apply_rule(%{"op" => op} = rule, payload, opts) do
    if op in @ops do
      case op do
        # coalesce and concat resolve their own paths against the payload.
        "coalesce" ->
          paths = (rule["args"]["paths"] || []) ++ List.wrap(rule["path"])
          first_present(paths, payload, rule)

        "concat" ->
          paths = (rule["args"]["paths"] || []) ++ List.wrap(rule["path"])

          parts =
            Enum.map(paths, fn path ->
              case get_path(payload, path) do
                {:ok, nil} -> nil
                {:ok, value} -> to_string(value)
                :error -> nil
              end
            end)

          if Enum.all?(parts, &is_nil/1) do
            {:error, {:missing_path, rule["path"]}}
          else
            {:ok, Enum.reject(parts, &is_nil/1) |> Enum.join(rule["args"]["separator"] || " ")}
          end

        "constant" ->
          {:ok, rule["args"]["value"]}

        "unmapped" ->
          {:ok, :unmapped}

        _ ->
          case resolve(rule, payload) do
            {:error, _} = err -> err
            {:ok, value} -> transform(op, value, rule["args"] || %{}, opts)
          end
      end
    else
      {:error, {:unknown_op, op}}
    end
  end

  defp apply_rule(rule, _payload, _opts), do: {:error, {:malformed_rule, Map.keys(rule)}}

  # ── path resolution ────────────────────────────────────────────────────────

  defp resolve(rule, payload) do
    case get_path(payload, rule["path"]) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_path, rule["path"]}}
      {:error, reason} when is_tuple(reason) or is_atom(reason) -> {:error, reason}
    end
  end

  defp first_present([], _payload, rule), do: {:error, {:missing_path, rule["path"]}}

  defp first_present([path | rest], payload, rule) do
    case get_path(payload, path) do
      {:ok, nil} -> first_present(rest, payload, rule)
      {:ok, value} -> {:ok, value}
      {:error, reason} when is_tuple(reason) or is_atom(reason) -> {:error, reason}
      :error -> first_present(rest, payload, rule)
    end
  end

  @doc """
  Resolves a dot-path. A segment suffixed `[]` (`Contacts[]`) descends into
  a list and takes its first element. String and atom keys are both accepted.
  """
  def get_path(payload, path) when is_binary(path) do
    segments = String.split(path, ".")

    Enum.reduce(segments, {:ok, payload}, fn
      # A named reason (ambiguous list, non-list descent) propagates — it
      # is data the steward must see, not a generic "missing".
      _segment, {:error, _reason} = err ->
        err

      _segment, :error ->
        :error

      segment, {:ok, current} when is_map(current) ->
        descend? = String.ends_with?(segment, "[]")
        prefix_len = byte_size(segment) - 2
        field = if descend?, do: binary_part(segment, 0, prefix_len), else: segment

        key =
          Enum.find([field, safe_atom(field)], fn k ->
            k != nil and Map.has_key?(current, k)
          end)

        case key do
          nil ->
            :error

          k ->
            case Map.get(current, k) do
              value when descend? and is_list(value) ->
                case value do
                  # ONE element: deterministic. Several: refusing beats
                  # silently importing the first and dropping the rest —
                  # that is silent data loss in a master-data import.
                  [first] -> {:ok, first}
                  [] -> :error
                  _multi -> {:error, :ambiguous_list}
                end

              value when descend? ->
                {:error, {:not_a_list, value}}

              value ->
                {:ok, value}
            end
        end

      _segment, _other ->
        :error
    end)
  end

  def get_path(_payload, path), do: {:error, {:missing_path, path}}

  # ── operators ──────────────────────────────────────────────────────────────

  defp transform("identity", v, _args, _opts), do: {:ok, v}
  defp transform("constant", v, _args, _opts), do: {:ok, v}
  defp transform("unmapped", _v, _args, _opts), do: {:ok, :unmapped}

  defp transform("cast", v, args, _opts) do
    case type_module(args["type"]) do
      {:ok, type} ->
        case Ash.Type.cast_input(type, v) do
          {:ok, casted} -> {:ok, casted}
          {:error, _} = err -> err
          :error -> {:error, {:cast_failed, args["type"], v}}
        end

      :error ->
        {:error, {:unknown_type, args["type"]}}
    end
  end

  defp transform("trim", v, _args, _opts) when is_binary(v), do: {:ok, String.trim(v)}
  defp transform("trim", v, _args, _opts), do: {:error, {:not_a_string, v}}

  defp transform("case", v, %{"mode" => mode}, _opts) when is_binary(v) do
    case mode do
      "down" -> {:ok, String.downcase(v)}
      "up" -> {:ok, String.upcase(v)}
      other -> {:error, {:unknown_case_mode, other}}
    end
  end

  defp transform("case", v, _args, _opts), do: {:error, {:not_a_string, v}}

  defp transform("parse_date", v, args, _opts) when is_binary(v) do
    order =
      case args["order"] do
        "mdy" -> :mdy
        "dmy" -> :dmy
        _ -> :none
      end

    case parse_date(String.trim(v), order) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, {:unparseable_date, v}}
    end
  end

  defp transform("parse_date", %Date{} = d, _args, _opts), do: {:ok, d}

  defp transform("parse_decimal", v, _args, _opts) do
    cleaned =
      v
      |> to_string()
      |> String.trim()
      |> String.replace(",", "")

    case Decimal.parse(cleaned) do
      {dec, ""} when is_struct(dec, Decimal) -> {:ok, dec}
      _ -> {:error, {:unparseable_decimal, v}}
    end
  end

  defp transform("decode", v, %{"table" => table}, _opts) when is_map(table) do
    key = to_string(v)

    case Map.fetch(table, key) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:undecodable_value, v}}
    end
  end

  defp transform("decode", _v, _args, _opts), do: {:error, {:missing_decode_table, nil}}

  defp transform("regex_extract", v, args, _opts) when is_binary(v) do
    case Regex.compile(args["pattern"] || "") do
      {:ok, re} ->
        case Regex.run(re, v) do
          nil -> {:ok, nil}
          captures -> {:ok, Enum.at(captures, args["group"] || 0)}
        end

      {:error, _} ->
        {:error, {:bad_regex, args["pattern"]}}
    end
  end

  defp transform("regex_extract", v, _args, _opts), do: {:error, {:not_a_string, v}}

  defp transform("ref_lookup", v, args, opts) do
    case Keyword.get(opts, :ref_resolver) do
      nil -> {:error, {:no_ref_resolver, args["kind"]}}
      resolver -> {:ok, resolver.(args["kind"], v)}
    end
  end

  defp transform("uuid_v5", v, args, _opts) do
    namespace =
      case args["namespace"] do
        "dns" ->
          <<0x6B, 0xA7, 0xB8, 0x10, 0x9D, 0xAD, 0x11, 0xD1, 0x80, 0xB4, 0x00, 0xC0, 0x4F, 0xD4,
            0x30, 0xC8>>

        "url" ->
          <<0x6B, 0xA7, 0xB8, 0x11, 0x9D, 0xAD, 0x11, 0xD1, 0x80, 0xB4, 0x00, 0xC0, 0x4F, 0xD4,
            0x30, 0xC8>>

        "oid" ->
          <<0x6B, 0xA7, 0xB8, 0x12, 0x9D, 0xAD, 0x11, 0xD1, 0x80, 0xB4, 0x00, 0xC0, 0x4F, 0xD4,
            0x30, 0xC8>>

        "x500" ->
          <<0x6B, 0xA7, 0xB8, 0x14, 0x9D, 0xAD, 0x11, 0xD1, 0x80, 0xB4, 0x00, 0xC0, 0x4F, 0xD4,
            0x30, 0xC8>>

        ns when is_binary(ns) and byte_size(ns) == 16 ->
          ns

        ns when is_binary(ns) ->
          case Ecto.UUID.cast(ns) do
            {:ok, uuid} -> Ecto.UUID.dump!(uuid)
            :error -> {:error, {:bad_namespace, ns}}
          end

        other ->
          {:error, {:bad_namespace, other}}
      end

    case namespace do
      {:error, _} = err ->
        err

      ns_bin ->
        # RFC 4122 v5: the digest IS the uuid; set the version nibble (5)
        # and the variant bits (10).
        <<tl::binary-size(6), _::4, th::bitstring-size(12), _::2, rest::bitstring-size(62),
          _::binary>> = :crypto.hash(:sha, ns_bin <> to_string(v))

        {:ok, Ecto.UUID.load!(<<tl::binary, 5::4, th::bitstring, 2::2, rest::bitstring>>)}
    end
  end

  defp type_module(t) do
    case t do
      "string" -> {:ok, Ash.Type.String}
      "ci_string" -> {:ok, Ash.Type.CiString}
      "integer" -> {:ok, Ash.Type.Integer}
      "decimal" -> {:ok, Ash.Type.Decimal}
      "boolean" -> {:ok, Ash.Type.Boolean}
      "date" -> {:ok, Ash.Type.Date}
      "utc_datetime" -> {:ok, Ash.Type.UTCDateTime}
      "map" -> {:ok, Ash.Type.Map}
      _ -> :error
    end
  end

  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp parse_date(v, order) do
    case Date.from_iso8601(v) do
      {:ok, date} ->
        {:ok, date}

      _ ->
        # Formats beyond ISO: YYYY/M/D is unambiguous; M/D vs D.M needs an
        # explicit order — 03/04/2026 silently swapped is exactly the
        # cross-region data error a master-data import must never commit.
        with [] <- iso_like(v, ~r|^(\d{4})[/\-.](\d{1,2})[/\-.](\d{1,2})$|),
             [] <- ordered_style(v, ~r|^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})$|, order) do
          :error
        else
          {:ok, date} -> {:ok, date}
        end
    end
  end

  defp iso_like(v, re) do
    case Regex.run(re, v) do
      [_, y, m, d] -> date(String.to_integer(y), String.to_integer(m), String.to_integer(d))
      _ -> []
    end
  end

  # Slash/dot styles resolve ONLY when the rule declared the order; the
  # other convention then refuses rather than silently swapping day/month.
  # The order is the WRITER's convention, independent of the punctuation.
  defp ordered_style(v, re, order) when order in [:mdy, :dmy] do
    case Regex.run(re, v) do
      [_, a, b, y] ->
        {m, d} = if order == :mdy, do: {a, b}, else: {b, a}
        date(String.to_integer(y), String.to_integer(m), String.to_integer(d))

      _ ->
        []
    end
  end

  defp ordered_style(_v, _re, _none), do: []

  defp date(y, m, d) do
    case Date.new(y, m, d) do
      {:ok, date} -> {:ok, date}
      _ -> []
    end
  end
end
