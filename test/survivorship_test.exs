# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.SurvivorshipTest do
  @moduledoc "The survivorship fold: per-attribute winners with provenance."

  use ExUnit.Case, async: true

  alias AshMdm.Survivorship

  @policy %{
    "default" => "non_null",
    "attributes" => %{
      "email" => %{"strategy" => "source_rank"},
      "name" => %{"strategy" => "most_recent"}
    },
    "source_rank" => ["salesforce", "manual_csv"]
  }

  defp rec(source, observed_at, attrs),
    do: %{record: source, source: source, observed_at: observed_at, attributes: attrs}

  @dt ~U[2026-01-01 00:00:00Z]

  test "source_rank picks the earliest-ranked source per attribute" do
    records = [
      rec("manual_csv", @dt, %{"email" => "csv@x.io", "name" => "Csv Name"}),
      rec("salesforce", @dt, %{"email" => "sf@x.io", "name" => nil})
    ]

    %{merged: merged, provenance: provenance} = Survivorship.resolve(@policy, records)

    assert merged["email"] == "sf@x.io"
    assert provenance["email"]["source"] == "salesforce"
    assert provenance["email"]["strategy"] == "source_rank"
  end

  test "most_recent picks the latest observed_at" do
    records = [
      rec("salesforce", ~U[2026-01-01 00:00:00Z], %{"name" => "Old Name"}),
      rec("manual_csv", ~U[2026-06-01 00:00:00Z], %{"name" => "New Name"})
    ]

    %{merged: merged, provenance: provenance} = Survivorship.resolve(@policy, records)

    assert merged["name"] == "New Name"
    assert provenance["name"]["source"] == "manual_csv"
    assert provenance["name"]["strategy"] == "most_recent"
  end

  test "non_null default skips nils and merges attributes across records" do
    policy = %{"default" => "non_null"}

    records = [
      rec("a", @dt, %{"email" => nil, "phone" => "555"}),
      rec("b", @dt, %{"email" => "b@x.io", "phone" => nil})
    ]

    %{merged: merged} = Survivorship.resolve(policy, records)

    assert merged == %{"email" => "b@x.io", "phone" => "555"}
  end

  test "most_complete wins the attribute when declared" do
    policy = %{"default" => "most_complete"}

    records = [
      rec("a", @dt, %{"notes" => "short"}),
      rec("b", @dt, %{"notes" => "much fuller notes text", "email" => "b@x.io"})
    ]

    %{merged: merged, provenance: provenance} = Survivorship.resolve(policy, records)

    assert merged["notes"] == "much fuller notes text"
    assert provenance["notes"]["source"] == "b"
  end

  test "all-nil keys stay absent with no provenance" do
    records = [rec("a", @dt, %{"fax" => nil}), rec("b", @dt, %{"fax" => nil})]

    %{merged: merged, provenance: provenance} = Survivorship.resolve(@policy, records)

    refute Map.has_key?(merged, "fax")
    refute Map.has_key?(provenance, "fax")
  end

  test "an unknown strategy resolves nothing for that key" do
    policy = %{"default" => "telepathy"}

    %{merged: merged} = Survivorship.resolve(policy, [rec("a", @dt, %{"x" => 1})])

    refute Map.has_key?(merged, "x")
  end
end
