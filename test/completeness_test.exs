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
end
