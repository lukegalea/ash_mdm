# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.CompletenessTest do
  @moduledoc "Assessing a golden's assertions against a declared purpose."

  use ExUnit.Case, async: true

  alias AshMdm.Assertions
  alias AshMdm.Completeness

  @now ~U[2026-06-01 00:00:00.000000Z]
  @recent ~U[2026-05-20 00:00:00.000000Z]
  @old ~U[2024-01-01 00:00:00.000000Z]

  defp need(attribute, extra \\ %{}) do
    Map.merge(%{"attribute" => attribute, "need" => "required", "because" => "why"}, extra)
  end

  defp statement(attribute, value, overrides \\ %{}) do
    Map.merge(
      %{
        id: "#{attribute}-#{inspect(value)}",
        golden_id: "g",
        attribute: attribute,
        value: Assertions.wrap_value(value),
        origin_kind: :import,
        origin_ref: %{"landing" => "l"},
        source: "crm",
        band: nil,
        observed_at: @recent,
        retracts_id: nil
      },
      overrides
    )
  end

  defp kind(requirement, assertions) do
    [%{kind: kind}] = Completeness.assess([requirement], assertions, now: @now)
    kind
  end

  test "a value that meets the requirement is satisfied" do
    assert kind(need("name"), [statement("name", "Acme")]) == :satisfied
  end

  test "no statement is missing" do
    assert kind(need("name"), []) == :missing
  end

  test "a retracted value is missing" do
    target = statement("name", "Acme", %{id: "t"})

    retraction =
      statement("name", nil, %{id: "r", origin_kind: :retraction, retracts_id: "t", value: nil})

    assert kind(need("name"), [target, retraction]) == :missing
  end

  test "a statement waiting on a person is missing, and counted as pending" do
    assertions = [statement("tax_id", "1", %{band: :review})]

    assert [%{kind: :missing, pending_count: 1, has_value: false}] =
             Completeness.assess([need("tax_id")], assertions, now: @now)
  end

  test "a retracted review statement is not pending" do
    target = statement("tax_id", "1", %{id: "t", band: :review})

    retraction =
      statement("tax_id", nil, %{id: "r", origin_kind: :retraction, retracts_id: "t", value: nil})

    assert [%{pending_count: 0}] =
             Completeness.assess([need("tax_id")], [target, retraction], now: @now)
  end

  test "an origin the purpose does not accept" do
    requirement = need("name", %{"accepted_origins" => ["human"]})
    assert kind(requirement, [statement("name", "Acme")]) == :origin_not_accepted
  end

  test "an accepted origin passes" do
    requirement = need("name", %{"accepted_origins" => ["human", "import"]})
    assert kind(requirement, [statement("name", "Acme")]) == :satisfied
  end

  test "a value past valid_until is expired" do
    assert kind(need("name"), [statement("name", "Acme", %{valid_until: @recent})]) == :expired
  end

  test "valid_until at this instant is expired" do
    assert kind(need("name"), [statement("name", "Acme", %{valid_until: @now})]) == :expired
  end

  test "a value older than max_age_days is stale" do
    requirement = need("name", %{"max_age_days" => 30})
    assert kind(requirement, [statement("name", "Acme", %{observed_at: @old})]) == :stale
  end

  test "a value inside max_age_days is satisfied" do
    assert kind(need("name", %{"max_age_days" => 30}), [statement("name", "Acme")]) == :satisfied
  end

  test "the worst kind wins when several apply" do
    requirement = need("name", %{"max_age_days" => 30, "accepted_origins" => ["human"]})

    assert kind(requirement, [
             statement("name", "Acme", %{observed_at: @old, valid_until: @recent})
           ]) ==
             :origin_not_accepted
  end

  test "optional and out-of-scope attributes are not assessed" do
    requirements = [
      %{"attribute" => "a", "need" => "optional", "because" => "nice"},
      %{"attribute" => "b", "need" => "out_of_scope", "because" => "never"}
    ]

    assert Completeness.assess(requirements, [], now: @now) == []
  end

  test "an assessment carries the because and the standing statement" do
    assertions = [statement("name", "Acme", %{id: "s", origin_kind: :human})]

    assert [
             %{
               because: "why",
               has_value: true,
               standing_origin: "human",
               assertion_id: "s",
               observed_at: @recent
             }
           ] = Completeness.assess([need("name")], assertions, now: @now)
  end

  test "an assessment never carries the value" do
    [assessment] =
      Completeness.assess([need("name")], [statement("name", "Secret", %{id: "s"})], now: @now)

    refute inspect(assessment) =~ "Secret"
  end

  describe "a requirement is judged against every statement holding the standing value" do
    defp accepting(attribute, origins, extra \\ %{}) do
      need(attribute, Map.merge(%{"accepted_origins" => origins}, extra))
    end

    test "an import later confirmed by an accepted origin closes the gap" do
      assertions = [
        statement("name", "Acme", %{id: "import", observed_at: @old}),
        statement("name", "Acme", %{id: "evidence", origin_kind: :evidence, source: "doc"})
      ]

      assert [
               %{
                 kind: :satisfied,
                 assertion_id: "evidence",
                 standing_origin: "evidence",
                 observed_at: @recent
               }
             ] = Completeness.assess([accepting("name", ["evidence"])], assertions, now: @now)
    end

    test "fresher evidence of the same value closes a staleness gap" do
      assertions = [
        statement("name", "Acme", %{id: "old", observed_at: @old}),
        statement("name", "Acme", %{id: "fresh", source: "erp", observed_at: @recent})
      ]

      assert [%{kind: :satisfied, assertion_id: "fresh", observed_at: @recent}] =
               Completeness.assess([need("name", %{"max_age_days" => 30})], assertions, now: @now)
    end

    test "a different value from an accepted origin does not" do
      assertions = [
        statement("name", "Acme", %{id: "import", observed_at: @old}),
        statement("name", "Other", %{id: "evidence", origin_kind: :evidence, source: "doc"})
      ]

      assert [
               %{
                 kind: :origin_not_accepted,
                 assertion_id: "import",
                 standing_origin: "import"
               }
             ] = Completeness.assess([accepting("name", ["evidence"])], assertions, now: @now)
    end

    test "a confirmation that doesn't compete doesn't close it" do
      assertions = [
        statement("name", "Acme", %{id: "import"}),
        statement("name", "Acme", %{
          id: "evidence",
          origin_kind: :evidence,
          source: "doc",
          band: :review
        })
      ]

      assert kind(accepting("name", ["evidence"]), assertions) == :origin_not_accepted
    end

    test "stale beats expired, and expired beats an origin not accepted" do
      stale = statement("name", "Acme", %{id: "stale", observed_at: @old, origin_kind: :human})

      expired =
        statement("name", "Acme", %{
          id: "expired",
          source: "erp",
          origin_kind: :evidence,
          valid_until: @recent
        })

      refused = statement("name", "Acme", %{id: "refused", source: "ops"})
      requirement = accepting("name", ["human", "evidence"], %{"max_age_days" => 30})

      assert [%{kind: :stale, assertion_id: "stale"}] =
               Completeness.assess([requirement], [expired, stale, refused], now: @now)

      assert [%{kind: :expired, assertion_id: "expired"}] =
               Completeness.assess([requirement], [expired, refused], now: @now)
    end

    test "equal outcomes go to the statement that holds longest, not the newest" do
      expiring = @now |> DateTime.add(1, :day)

      assertions = [
        statement("name", "Acme", %{id: "lasting", source: "erp", observed_at: @old}),
        statement("name", "Acme", %{id: "soon", observed_at: @recent, valid_until: expiring})
      ]

      assert [%{kind: :satisfied, assertion_id: "lasting", valid_until: nil}] =
               Completeness.assess([need("name")], assertions, now: @now)
    end

    test "a value going stale first loses to one that lasts" do
      requirement = need("name", %{"max_age_days" => 30})
      fresh_until_june = DateTime.add(@now, -29, :day)

      assertions = [
        statement("name", "Acme", %{id: "aging", source: "erp", observed_at: fresh_until_june}),
        statement("name", "Acme", %{
          id: "soon",
          observed_at: @recent,
          valid_until: DateTime.add(@now, 1, :hour)
        })
      ]

      assert [%{assertion_id: "aging"}] =
               Completeness.assess([requirement], assertions, now: @now)
    end

    test "equal outcomes go to the newest statement" do
      assertions = [
        statement("name", "Acme", %{id: "older", source: "erp", observed_at: @old}),
        statement("name", "Acme", %{id: "newer", observed_at: @recent})
      ]

      assert [%{kind: :satisfied, assertion_id: "newer", observed_at: @recent}] =
               Completeness.assess([need("name")], assertions, now: @now)
    end
  end

  test "gaps/3 leaves out what is satisfied" do
    requirements = [need("name"), need("email")]

    assert [%{attribute: "email", kind: :missing}] =
             Completeness.gaps(requirements, [statement("name", "Acme")], now: @now)
  end

  test "the standing statement follows the survivorship policy" do
    policy = %{"default" => "origin_rank", "origin_rank" => ["human", "import"]}

    assertions = [
      statement("name", "Old", %{id: "a"}),
      statement("name", "Person", %{id: "b", origin_kind: :human, observed_at: @now})
    ]

    assert [%{assertion_id: "b"}] =
             Completeness.assess([need("name")], assertions, now: @now, policy: policy)
  end

  describe "the incumbent option" do
    test "assess reports the incumbent's origin when it stands" do
      held =
        statement("name", "Held", %{id: "held", origin_kind: :enrichment, observed_at: @recent})

      history = statement("name", "History", %{id: "old", source: "mail", observed_at: @old})
      incumbent = &(&1.id == "held")

      assert [%{assertion_id: "old", standing_origin: "import"}] =
               Completeness.assess([need("name")], [held, history], now: @now)

      assert [%{assertion_id: "held", standing_origin: "enrichment"}] =
               Completeness.assess([need("name")], [held, history],
                 now: @now,
                 incumbent: incumbent
               )
    end

    test "a non-function raises" do
      assert_raise ArgumentError, fn ->
        Completeness.assess([need("name")], [statement("name", "A")], now: @now, incumbent: 1)
      end
    end
  end
end
