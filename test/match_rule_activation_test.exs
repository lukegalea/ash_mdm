# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.MatchRuleActivationTest do
  @moduledoc "Activation refuses rules that would score wrongly without complaint."

  use ExUnit.Case, async: false

  alias AshMdm.Fixtures.MatchRuleSet

  @moduletag :db

  @exact %{"name" => "e", "kind" => "exact", "fields" => ["email"], "weight" => 1.0}
  @fuzzy %{"name" => "f", "kind" => "fuzzy", "field" => "name", "algorithm" => "jaro"}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp activate(rules) do
    MatchRuleSet
    |> Ash.Changeset.for_create(:draft, %{
      golden_resource: "golden-#{System.unique_integer([:positive])}",
      rules: rules,
      survivorship: %{}
    })
    |> Ash.create!(authorize?: false)
    |> Ash.Changeset.for_update(:activate)
    |> Ash.update(authorize?: false)
  end

  test "accepts well-formed rules, weight optional" do
    assert {:ok, %{status: :active}} = activate([@exact, @fuzzy])
  end

  test "accepts known standardizers" do
    rule = Map.put(@fuzzy, "standardize", ["unaccent", "legal_suffix"])
    assert {:ok, %{status: :active}} = activate([rule])
  end

  for {label, rule} <- [
        {"an unknown kind", %{"name" => "x", "kind" => "soundex", "field" => "name"}},
        {"no name", %{"kind" => "exact", "fields" => ["email"]}},
        {"exact with no fields", %{"name" => "x", "kind" => "exact", "fields" => []}},
        {"fuzzy with no field", %{"name" => "x", "kind" => "fuzzy"}},
        {"an unknown algorithm",
         %{"name" => "x", "kind" => "fuzzy", "field" => "n", "algorithm" => "soundex"}},
        {"a zero weight", %{"name" => "x", "kind" => "fuzzy", "field" => "n", "weight" => 0}},
        {"a text weight", %{"name" => "x", "kind" => "fuzzy", "field" => "n", "weight" => "1"}},
        {"an unknown standardizer",
         %{"name" => "x", "kind" => "fuzzy", "field" => "n", "standardize" => ["phonetic"]}},
        {"standardize not a list",
         %{"name" => "x", "kind" => "fuzzy", "field" => "n", "standardize" => "lei"}}
      ] do
    test "refuses #{label}" do
      assert {:error, _} = activate([unquote(Macro.escape(rule))])
    end
  end

  describe "activation on a global-tenancy host" do
    alias AshMdm.Fixtures.TenantMatchRuleSet

    @golden "AshMdm.Fixtures.Person"

    defp tenant_draft!(tenant) do
      TenantMatchRuleSet
      |> Ash.Changeset.for_create(
        :draft,
        %{golden_resource: @golden, rules: [@exact], survivorship: %{}},
        tenant: tenant
      )
      |> Ash.create!(authorize?: false)
    end

    defp activate_with_no_tenant!(id) do
      TenantMatchRuleSet
      |> Ash.get!(id, authorize?: false)
      |> Ash.Changeset.for_update(:activate)
      |> Ash.update!(authorize?: false)
    end

    defp status_of(id), do: Ash.get!(TenantMatchRuleSet, id, authorize?: false).status

    test "leaves another tenant's active set alone" do
      theirs = tenant_draft!(Ecto.UUID.generate())
      ours = tenant_draft!(Ecto.UUID.generate())

      activate_with_no_tenant!(theirs.id)
      activate_with_no_tenant!(ours.id)

      assert status_of(theirs.id) == :active
      assert status_of(ours.id) == :active
    end

    test "still retires the same tenant's earlier set" do
      org = Ecto.UUID.generate()
      earlier = tenant_draft!(org)
      later = tenant_draft!(org)

      activate_with_no_tenant!(earlier.id)
      activate_with_no_tenant!(later.id)

      assert status_of(earlier.id) == :retired
      assert status_of(later.id) == :active
    end
  end

  describe "the one-active index" do
    defp insert_active(golden_resource) do
      Ecto.Adapters.SQL.query(
        AshMdm.Test.Repo,
        """
        INSERT INTO mdm_match_rule_sets
          (id, golden_resource, rules, status, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, '[]', 'active', now(), now())
        """,
        [golden_resource]
      )
    end

    test "the database refuses two active sets for one golden resource" do
      golden = "golden-#{System.unique_integer([:positive])}"

      assert {:ok, _} = insert_active(golden)

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               insert_active(golden)
    end

    test "another golden resource is free" do
      assert {:ok, _} = insert_active("golden-#{System.unique_integer([:positive])}")
      assert {:ok, _} = insert_active("golden-#{System.unique_integer([:positive])}")
    end
  end

  test "refuses two rules with one name" do
    assert {:error, _} = activate([@exact, %{@fuzzy | "name" => "e"}])
  end
end
