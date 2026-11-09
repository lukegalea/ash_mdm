# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.ResolverTest do
  @moduledoc "The resolver lifecycle and its validator, against the database."

  use ExUnit.Case, async: false

  alias AshMdm.Fixtures.Resolver

  @moduletag :db
  @golden "AshMdm.Fixtures.Person"

  require Ash.Query

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp input(overrides \\ %{}) do
    Map.merge(
      %{
        golden_resource: @golden,
        name: "registry_lookup",
        kind: "enrichment",
        produces: ["email"],
        requires: ["name"],
        cost_rank: 10,
        reference: %{"operation" => "lookup"}
      },
      overrides
    )
  end

  defp draft!(overrides \\ %{}) do
    Resolver
    |> Ash.Changeset.for_create(:draft, input(overrides))
    |> Ash.create!(authorize?: false)
  end

  defp run(resolver, action, input \\ %{}) do
    resolver |> Ash.Changeset.for_update(action, input) |> Ash.update!(authorize?: false)
  end

  defp checks_of(resolver) do
    errors = resolver.validation_findings[:errors] || resolver.validation_findings["errors"] || []
    Enum.map(errors, &to_string(&1[:check] || &1["check"]))
  end

  defp refused(overrides, check) do
    resolver = overrides |> draft!() |> run(:validate)
    assert resolver.status == :draft
    assert check in checks_of(resolver)
  end

  describe "validate" do
    test "a sound resolver is validated" do
      assert %{status: :validated} = draft!() |> run(:validate)
    end

    test "every closed kind is accepted" do
      for kind <- AshMdm.Resolution.kinds() do
        assert %{status: :validated} = %{kind: kind} |> draft!() |> run(:validate)
      end
    end

    test "requires may be empty" do
      assert %{status: :validated} = %{requires: []} |> draft!() |> run(:validate)
    end

    test "refuses an unknown kind" do
      refused(%{kind: "oracle"}, "unknown_kind")
    end

    test "kinds are matched exactly" do
      refused(%{kind: "Human"}, "unknown_kind")
    end

    test "an empty kind cannot be drafted" do
      assert_raise Ash.Error.Invalid, fn -> draft!(%{kind: ""}) end
    end

    test "refuses empty produces" do
      refused(%{produces: []}, "empty_produces")
    end

    test "refuses an attribute in both produces and requires" do
      refused(%{produces: ["email"], requires: ["email"]}, "produces_and_requires")
    end

    test "refuses a cost of zero" do
      refused(%{cost_rank: 0}, "bad_cost_rank")
    end

    test "refuses a negative cost" do
      refused(%{cost_rank: -3}, "bad_cost_rank")
    end

    test "refuses an empty reference" do
      refused(%{reference: %{}}, "bad_reference")
    end

    test "a blank attribute name cannot even be drafted" do
      assert_raise Ash.Error.Invalid, fn -> draft!(%{produces: [" "]}) end
      assert_raise Ash.Error.Invalid, fn -> draft!(%{requires: [""]}) end
    end

    test "refuses an attribute the golden does not have" do
      refused(%{produces: ["nickname"]}, "unknown_attribute")
      refused(%{requires: ["nickname"]}, "unknown_attribute")
    end

    test "refuses a golden the host has not allowed" do
      refused(%{golden_resource: "Nope"}, "unknown_target")
    end

    test "a missing cost or reference cannot even be drafted" do
      for field <- [:cost_rank, :reference, :produces, :kind, :name] do
        assert_raise Ash.Error.Invalid, fn ->
          Resolver
          |> Ash.Changeset.for_create(:draft, Map.delete(input(), field))
          |> Ash.create!(authorize?: false)
        end
      end
    end

    test "a cost that is not a number cannot be drafted" do
      assert_raise Ash.Error.Invalid, fn -> draft!(%{cost_rank: "cheap"}) end
    end

    test "an empty name cannot be drafted" do
      assert_raise Ash.Error.Invalid, fn -> draft!(%{name: ""}) end
    end
  end

  describe "tenancy" do
    alias AshMdm.Fixtures.TenantResolver

    defp tenant_draft!(tenant, overrides \\ %{}) do
      TenantResolver
      |> Ash.Changeset.for_create(:draft, input(overrides), tenant: tenant)
      |> Ash.create!(authorize?: false)
    end

    defp tenant_run(resolver, action, tenant) do
      resolver
      |> Ash.Changeset.for_update(action, %{}, tenant: tenant)
      |> Ash.update!(authorize?: false)
    end

    defp version_input(from),
      do: %{
        from_resolver_id: from,
        kind: "inference",
        produces: ["email"],
        cost_rank: 2,
        reference: %{"operation" => "infer"}
      }

    test "a new version is linked and supersedes inside its tenant" do
      org = Ecto.UUID.generate()
      first = org |> tenant_draft!() |> tenant_run(:validate, org) |> tenant_run(:activate, org)

      second =
        TenantResolver
        |> Ash.Changeset.for_create(:create_version, version_input(first.id), tenant: org)
        |> Ash.create!(authorize?: false)
        |> tenant_run(:validate, org)
        |> tenant_run(:activate, org)

      assert second.version == 2
      assert second.root_id == first.id
      assert second.organization_id == org

      assert %{status: :retired} =
               Ash.get!(TenantResolver, first.id, tenant: org, authorize?: false)
    end

    test "another tenant's resolver cannot be the predecessor" do
      theirs = Ecto.UUID.generate() |> tenant_draft!()
      ours = Ecto.UUID.generate()

      assert {:error, %Ash.Error.Invalid{}} =
               TenantResolver
               |> Ash.Changeset.for_create(:create_version, version_input(theirs.id),
                 tenant: ours
               )
               |> Ash.create(authorize?: false)
    end

    test "activation leaves another tenant's active resolver alone" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      theirs = a |> tenant_draft!() |> tenant_run(:validate, a) |> tenant_run(:activate, a)
      b |> tenant_draft!() |> tenant_run(:validate, b) |> tenant_run(:activate, b)

      assert %{status: :active} =
               Ash.get!(TenantResolver, theirs.id, tenant: a, authorize?: false)
    end
  end

  describe "activate" do
    test "needs a validated resolver" do
      assert_raise Ash.Error.Invalid, fn -> draft!() |> run(:activate) end
    end

    test "a refused draft cannot be activated" do
      resolver = %{kind: "oracle"} |> draft!() |> run(:validate)
      assert_raise Ash.Error.Invalid, fn -> run(resolver, :activate) end
    end

    test "a new version retires its predecessor and keeps the chain" do
      first = draft!() |> run(:validate) |> run(:activate)

      second =
        Resolver
        |> Ash.Changeset.for_create(:create_version, %{
          from_resolver_id: first.id,
          kind: "inference",
          produces: ["email"],
          requires: [],
          cost_rank: 2,
          reference: %{"operation" => "infer"}
        })
        |> Ash.create!(authorize?: false)
        |> run(:validate)
        |> run(:activate)

      assert second.golden_resource == @golden
      assert second.name == "registry_lookup"
      assert second.version == 2
      assert second.root_id == first.id
      assert second.supersedes_id == first.id
      assert second.status == :active
      assert second.content_hash != first.content_hash
      assert %{status: :retired} = Ash.get!(Resolver, first.id, authorize?: false)
    end

    test "a version cannot rename itself" do
      first = draft!()

      second =
        Resolver
        |> Ash.Changeset.for_create(:create_version, %{
          from_resolver_id: first.id,
          name: "other",
          kind: "enrichment",
          produces: ["email"],
          cost_rank: 1,
          reference: %{"a" => 1}
        })

      refute second.valid?
    end

    test "a new version of something that does not exist is refused, not a crash" do
      changeset =
        Resolver
        |> Ash.Changeset.for_create(:create_version, %{
          from_resolver_id: Ecto.UUID.generate(),
          kind: "enrichment",
          produces: ["email"],
          cost_rank: 1,
          reference: %{"a" => 1}
        })

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
    end

    test "a stale copy of a since-retired version cannot bring it back" do
      validated = draft!() |> run(:validate)
      first = run(validated, :activate)

      second =
        Resolver
        |> Ash.Changeset.for_create(:create_version, %{
          from_resolver_id: first.id,
          kind: "inference",
          produces: ["email"],
          cost_rank: 2,
          reference: %{"operation" => "infer"}
        })
        |> Ash.create!(authorize?: false)
        |> run(:validate)
        |> run(:activate)

      assert {:error, _} =
               validated
               |> Ash.Changeset.for_update(:activate, %{})
               |> Ash.update(authorize?: false)

      assert %{status: :active} = Ash.get!(Resolver, second.id, authorize?: false)
      assert %{status: :retired} = Ash.get!(Resolver, first.id, authorize?: false)
    end

    test "a stale copy of a draft cannot pull an active resolver back" do
      stale = draft!()
      active = stale |> run(:validate) |> run(:activate)

      assert {:error, _} =
               stale |> Ash.Changeset.for_update(:validate, %{}) |> Ash.update(authorize?: false)

      assert %{status: :active} = Ash.get!(Resolver, active.id, authorize?: false)
    end

    test "another name stays active alongside" do
      draft!() |> run(:validate) |> run(:activate)
      draft!(%{name: "second"}) |> run(:validate) |> run(:activate)

      active = Resolver |> Ash.Query.filter(status == :active) |> Ash.read!(authorize?: false)
      assert length(active) == 2
    end

    test "active rows plan directly" do
      draft!() |> run(:validate) |> run(:activate)
      active = Resolver |> Ash.Query.filter(status == :active) |> Ash.read!(authorize?: false)

      assert [%{status: :planned, resolver: "registry_lookup", kind: "enrichment"}] =
               AshMdm.Resolution.plan([%{attribute: "email", material: false}], active, ["name"])
    end
  end
end

defmodule AshMdm.Resolution.ValidatorTest do
  @moduledoc "Inputs the resource's own casting would keep out, refused by the gate anyway."

  use ExUnit.Case, async: true

  alias AshMdm.Resolution.Validator

  @sound %{
    golden_resource: "AshMdm.Fixtures.Person",
    kind: "inference",
    produces: ["email"],
    requires: ["name"],
    cost_rank: 1,
    reference: %{"a" => 1}
  }

  defp checks(overrides),
    do:
      @sound
      |> Map.merge(overrides)
      |> Validator.findings()
      |> Map.fetch!(:errors)
      |> Enum.map(& &1.check)

  test "a sound resolver has no findings" do
    assert checks(%{}) == []
  end

  test "malformed produces" do
    assert :bad_produces in checks(%{produces: ["email", " "]})
    assert :bad_produces in checks(%{produces: "email"})
    assert :bad_produces in checks(%{produces: [:email]})
  end

  test "malformed requires" do
    assert :bad_requires in checks(%{requires: [""]})
    assert :bad_requires in checks(%{requires: "name"})
  end

  test "missing produces is empty produces" do
    assert :empty_produces in checks(%{produces: nil})
  end

  test "missing or malformed cost, kind and reference" do
    assert :bad_cost_rank in checks(%{cost_rank: nil})
    assert :bad_cost_rank in checks(%{cost_rank: 1.5})
    assert :unknown_kind in checks(%{kind: nil})
    assert :unknown_kind in checks(%{kind: :human})
    assert :bad_reference in checks(%{reference: nil})
    assert :bad_reference in checks(%{reference: "run it"})
  end
end
