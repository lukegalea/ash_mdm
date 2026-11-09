# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.SensitiveAssertionTest do
  @moduledoc "A sensitive value's content digest is keyed; a plain one is not."

  use ExUnit.Case, async: false

  alias AshMdm.Fixtures.AttributeAssertion
  alias AshMdm.Fixtures.SensitiveAttributeAssertion
  alias AshMdm.Mapping.ContentHash

  @moduletag :db

  require Ash.Query

  @observed_at ~U[2026-01-01 00:00:00.000000Z]

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshMdm.Test.Repo)
    :ok
  end

  defp input do
    %{
      golden_resource: "AshMdm.Fixtures.Person",
      golden_id: Ash.UUID.generate(),
      attribute: "sin",
      value: "046454286",
      origin_kind: :import,
      origin_ref: %{"landing" => "l-1"},
      source: "crm",
      observed_at: @observed_at
    }
  end

  defp seal!(resource, input) do
    resource |> Ash.Changeset.for_create(:assert, input) |> Ash.create!(authorize?: false)
  end

  defp canonical_content(input) do
    %{
      golden_resource: input.golden_resource,
      golden_id: input.golden_id,
      attribute: input.attribute,
      origin_kind: input.origin_kind,
      origin_ref: input.origin_ref,
      source: input.source,
      band: nil,
      confidence: nil,
      observed_at: input.observed_at,
      valid_until: nil,
      retracts_id: nil,
      value: %{"v" => input.value}
    }
  end

  test "the digest is an HMAC under the secret, over the same canonical content" do
    input = input()
    row = seal!(SensitiveAttributeAssertion, input)

    expected = ContentHash.hmac!(canonical_content(input), AshMdm.Fixtures.DigestSecret.fetch())

    assert row.content_digest == expected
    assert row.content_digest =~ ~r/^[0-9a-f]{64}$/
  end

  test "the digest is not the plain hash of the content" do
    input = input()
    row = seal!(SensitiveAttributeAssertion, input)

    refute row.content_digest == ContentHash.hash!(canonical_content(input))
  end

  test "writing the same statement twice is still one row" do
    input = input()
    seal!(SensitiveAttributeAssertion, input)
    seal!(SensitiveAttributeAssertion, input)

    assert SensitiveAttributeAssertion
           |> Ash.Query.filter(golden_id == ^input.golden_id)
           |> Ash.count!(authorize?: false) == 1
  end

  test "a non-sensitive assertion is the plain hash, unchanged" do
    input = input()
    row = seal!(AttributeAssertion, input)

    assert row.content_digest == ContentHash.hash!(canonical_content(input))
  end

  test "the value and the digest are marked sensitive" do
    sensitive = Ash.Resource.Info.attribute(SensitiveAttributeAssertion, :content_digest)
    assert sensitive.sensitive?
    assert Ash.Resource.Info.attribute(SensitiveAttributeAssertion, :value).sensitive?

    refute Ash.Resource.Info.attribute(AttributeAssertion, :content_digest).sensitive?
  end
end
