# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.EvaluatorTest do
  @moduledoc "The evaluator fold over fixture field rules; no database."

  use ExUnit.Case, async: true

  alias AshMdm.Mapping.Evaluator

  describe "operators" do
    test "identity passes the value through" do
      assert run([rule("email", "email", "identity")], %{"email" => " A@B.C "}) ==
               {:ok, %{"email" => " A@B.C "}}
    end

    test "each rule reads its path from the source payload; composition is not chaining" do
      rules = [
        rule("email", "email_trimmed", "trim"),
        rule("email", "email_lower", "case", %{"mode" => "down"})
      ]

      assert run(rules, %{"email" => "  A@B.C  "}) ==
               {:ok,
                %{
                  "email_trimmed" => "A@B.C",
                  "email_lower" => "  a@b.c  "
                }}
    end

    test "cast to integer" do
      assert run([rule("n", "n", "cast", %{"type" => "integer"})], %{"n" => "42"}) ==
               {:ok, %{"n" => 42}}
    end

    test "parse_date handles ISO and enterprise shapes" do
      rules = [rule("joined_on", "joined_on", "parse_date")]

      assert run(rules, %{"joined_on" => "2026-01-31"}) == {:ok, %{"joined_on" => ~D[2026-01-31]}}
      assert run(rules, %{"joined_on" => "01/31/2026"}) == {:ok, %{"joined_on" => ~D[2026-01-31]}}
      assert run(rules, %{"joined_on" => "31.01.2026"}) == {:ok, %{"joined_on" => ~D[2026-01-31]}}

      assert {:error, {:rule, _, {:unparseable_date, "not a date"}}} =
               run(rules, %{"joined_on" => "not a date"})
    end

    test "parse_decimal strips thousands separators" do
      assert run([rule("amount", "amount", "parse_decimal")], %{"amount" => "1,234.50"}) ==
               {:ok, %{"amount" => Decimal.new("1234.50")}}
    end

    test "decode maps through the value table" do
      rule = rule("tier", "tier", "decode", %{"table" => %{"P" => "premium", "S" => "standard"}})

      assert run([rule], %{"tier" => "P"}) == {:ok, %{"tier" => "premium"}}
      assert {:error, {:rule, _, {:undecodable_value, "X"}}} = run([rule], %{"tier" => "X"})
    end

    test "coalesce falls through to the first present path" do
      rule = %{
        "path" => "primary_email",
        "target" => "email",
        "op" => "coalesce",
        "args" => %{"paths" => ["work_email"]},
        "required" => false
      }

      assert run([rule], %{"work_email" => "w@x.io"}) == {:ok, %{"email" => "w@x.io"}}
      assert run([rule], %{"primary_email" => "p@x.io"}) == {:ok, %{"email" => "p@x.io"}}
      assert {:error, {:rule, _, {:missing_path, "primary_email"}}} = run([rule], %{})
    end

    test "constant ignores the payload" do
      assert run([rule(nil, "tier", "constant", %{"value" => "bronze"})], %{}) ==
               {:ok, %{"tier" => "bronze"}}
    end

    test "regex_extract returns the named group" do
      rule = rule("phone", "phone", "regex_extract", %{"pattern" => ~S|\d+|, "group" => 0})

      assert run([rule], %{"phone" => "call (555) 123"}) == {:ok, %{"phone" => "555"}}
    end

    test "uuid_v5 is deterministic, namespaced, and RFC-correct" do
      rule = rule("ref", "ref", "uuid_v5", %{"namespace" => "dns"})

      # RFC 4122 worked example: DNS namespace + "www.example.com".
      {:ok, %{"ref" => rfc}} = run([rule], %{"ref" => "www.example.com"})
      assert rfc == "2ed6657d-e927-568b-95e1-2665a8aea6a2"

      {:ok, uuid1} = run([rule], %{"ref" => "acme-42"})
      {:ok, uuid2} = run([rule], %{"ref" => "acme-42"})
      {:ok, uuid3} = run([rule], %{"ref" => "acme-43"})

      assert uuid1 == uuid2
      assert uuid1 != uuid3
    end

    test "ref_lookup requires a resolver" do
      rule = rule("currency", "currency", "ref_lookup", %{"kind" => "currency"})

      assert {:error, {:rule, _, {:no_ref_resolver, "currency"}}} =
               run([rule], %{"currency" => "USD"})

      assert run([rule], %{"currency" => "usd"},
               ref_resolver: fn "currency", v -> String.upcase(v) end
             ) ==
               {:ok, %{"currency" => "USD"}}
    end

    test "unmapped emits nothing" do
      assert run([rule(nil, "notes", "unmapped", %{}, %{"because" => "not needed"})], %{}) ==
               {:ok, %{}}
    end

    test "unknown operator is an error, never a fallback" do
      assert {:error, {:rule, _, {:unknown_op, "eval"}}} =
               run([rule("a", "a", "eval")], %{"a" => 1})
    end
  end

  describe "path resolution" do
    test "nested dot-paths" do
      payload = %{"raw_payload" => %{"Contact" => %{"Email" => "a@b.c"}}}

      assert run([rule("raw_payload.Contact.Email", "email", "identity")], payload) ==
               {:ok, %{"email" => "a@b.c"}}
    end

    test "[] descends into a list and takes the first element" do
      payload = %{"Contacts" => [%{"Email" => "first@x.io"}, %{"Email" => "second@x.io"}]}

      assert run([rule("Contacts[].Email", "email", "identity")], payload) ==
               {:ok, %{"email" => "first@x.io"}}
    end

    test "missing path is a rule error naming the path" do
      assert {:error, {:rule, rule, {:missing_path, "Email Address"}}} =
               run([rule("Email Address", "email", "identity")], %{})

      assert rule["path"] == "Email Address"
    end
  end

  defp rule(path, target, op, args \\ %{}, extra \\ %{}) do
    %{"path" => path, "target" => target, "op" => op, "args" => args}
    |> Map.merge(extra)
  end

  defp run(rules, payload, opts \\ []), do: Evaluator.run(rules, payload, opts)
end
