# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Mapping.DiffTest do
  @moduledoc """
  Two versions of a schema mapping compared by what they do (`AshMdm.Mapping.Diff`): the
  target they write and each field rule by the field it writes, never rule order.
  """

  use ExUnit.Case, async: false

  import AshMdm.TestHelpers

  alias AshMdm.Mapping.Diff

  defp mapping(rules, overrides \\ %{}) do
    Map.merge(
      %{
        direction: :ingress,
        source: "clinic_csv",
        stream: "patients",
        target_resource: "Patient",
        version: 1,
        field_rules: rules
      },
      overrides
    )
  end

  defp email(path), do: %{"path" => path, "target" => "email", "op" => "trim", "args" => %{}}

  defp name_rule,
    do: %{"path" => "Full Name", "target" => "name", "op" => "identity", "args" => %{}}

  describe "diff/2" do
    test "aspects are listed in reading order, each with a label" do
      assert Keyword.keys(Diff.aspects()) == [:target, :fields]
      assert Enum.all?(Diff.aspects(), fn {_aspect, label} -> is_binary(label) end)
    end

    test "a changed source path is one field change, named by field and property" do
      assert [
               %{
                 aspect: :fields,
                 kind: :changed,
                 subject: "email",
                 option: "path",
                 from: "Email",
                 to: "Email Address"
               }
             ] = Diff.diff(mapping([email("Email")]), mapping([email("Email Address")]))
    end

    test "a version compared with itself, or with its rules reordered, has no changes" do
      old = mapping([email("Email"), name_rule()])

      assert Diff.diff(old, old) == []
      assert Diff.diff(old, mapping([name_rule(), email("Email")])) == []
    end

    test "fields are added and removed by the field they write" do
      unmapped = %{
        "path" => nil,
        "target" => "tier",
        "op" => "unmapped",
        "args" => %{},
        "because" => "not carried"
      }

      changes =
        Diff.diff(mapping([email("Email"), name_rule()]), mapping([email("Email"), unmapped]))

      assert %{
               aspect: :fields,
               kind: :removed,
               subject: "name",
               option: nil,
               from: %{"path" => "Full Name", "op" => "identity", "args" => %{}},
               to: nil
             } in changes

      assert %{
               aspect: :fields,
               kind: :added,
               subject: "tier",
               option: nil,
               from: nil,
               to: %{"path" => nil, "op" => "unmapped", "args" => %{}, "because" => "not carried"}
             } in changes

      assert length(changes) == 2
    end

    test "an operator, its arguments and required compare property by property" do
      old = %{
        "path" => "Joined",
        "target" => "joined_on",
        "op" => "parse_date",
        "args" => %{"format" => "{YYYY}-{0M}-{0D}"}
      }

      new = Map.merge(old, %{"args" => %{"format" => "{0D}/{0M}/{YYYY}"}, "required" => true})

      assert [
               %{subject: "joined_on", option: "args", from: %{"format" => _}, to: %{}},
               %{subject: "joined_on", option: "required", from: nil, to: true}
             ] = Diff.diff(mapping([old]), mapping([new]))
    end

    test "the target is compared property by property" do
      changes =
        Diff.diff(
          mapping([email("Email")]),
          mapping([email("Email")], %{stream: "clients", target_resource: "Client"})
        )

      assert [
               %{
                 aspect: :target,
                 kind: :changed,
                 subject: "resource",
                 option: nil,
                 from: "Patient",
                 to: "Client"
               },
               %{aspect: :target, kind: :changed, subject: "stream", from: "patients"}
             ] = changes
    end

    test "two rules for one field are both compared" do
      old = mapping([email("Email"), email("Work Email")])
      new = mapping([email("Email"), email("Office Email")])

      assert [%{subject: "email (2)", option: "path", from: "Work Email", to: "Office Email"}] =
               Diff.diff(old, new)

      assert [%{kind: :removed, subject: "email (2)"}] =
               Diff.diff(old, mapping([email("Email")]))
    end

    test "a mapping with no field rules compares as empty" do
      changes = Diff.diff(mapping(nil), mapping([email("Email"), name_rule()]))

      assert Enum.map(changes, &{&1.aspect, &1.kind, &1.subject}) == [
               {:fields, :added, "email"},
               {:fields, :added, "name"}
             ]
    end

    test "every change is a plain map in one of the aspects" do
      changes =
        Diff.diff(
          mapping([email("Email")]),
          mapping([name_rule()], %{direction: :egress})
        )

      aspects = Keyword.keys(Diff.aspects())
      assert changes != []

      for change <- changes do
        refute is_struct(change)
        assert change.aspect in aspects
        assert Map.keys(change) |> Enum.sort() == [:aspect, :from, :kind, :option, :subject, :to]
      end
    end
  end

  describe "over stored mapping versions" do
    @describetag :db

    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
      :ok
    end

    test "a version read back from the database compares by its rules, not their order" do
      v1 = draft!(field_rules: [email("Email"), name_rule()])
      reordered = draft!(field_rules: [name_rule(), email("Email")])
      changed = draft!(field_rules: [email("Email Address"), name_rule()])

      [v1, reordered, changed] = Enum.map([v1, reordered, changed], &Ash.reload!/1)

      assert v1.content_hash != reordered.content_hash
      assert Diff.diff(v1, reordered) == []

      assert [%{aspect: :fields, subject: "email", option: "path", to: "Email Address"}] =
               Diff.diff(v1, changed)
    end
  end
end
