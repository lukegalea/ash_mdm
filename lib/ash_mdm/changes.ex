# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Changes.SetContentHash do
  @moduledoc "Stamps `content_hash` from the canonical field_rules JSON."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      hash =
        AshMdm.Mapping.ContentHash.hash!(Ash.Changeset.get_attribute(changeset, :field_rules))

      Ash.Changeset.force_change_attribute(changeset, :content_hash, hash)
    end)
  end
end

defmodule AshMdm.Changes.OpenVersionChain do
  @moduledoc "A fresh chain roots at its own id."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # Generate the id in the changeset so the chain can root at it without
      # a second write.
      id = Ash.Changeset.get_attribute(changeset, :id) || Ecto.UUID.generate()

      changeset
      |> Ash.Changeset.force_change_attribute(:id, id)
      |> Ash.Changeset.force_change_attribute(:root_id, id)
    end)
  end
end

defmodule AshMdm.Changes.LinkVersionChain do
  @moduledoc """
  Derives the version-chain linkage from the `:from_mapping_id` predecessor:
  `root_id`, `version + 1`, `supersedes_id`. The predecessor is untouched —
  nothing is overwritten, ever.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      {:ok, predecessor} =
        Ash.get(changeset.resource, Ash.Changeset.get_argument(changeset, :from_mapping_id),
          authorize?: false
        )

      changeset
      |> Ash.Changeset.change_attribute(:supersedes_id, predecessor.id)
      |> Ash.Changeset.change_attribute(:root_id, predecessor.root_id || predecessor.id)
      |> Ash.Changeset.change_attribute(:version, (predecessor.version || 1) + 1)
      |> Ash.Changeset.change_attribute(:status, :draft)
    end)
  end
end

defmodule AshMdm.Changes.RunValidation do
  @moduledoc """
  Runs `AshMdm.Mapping.Validator.findings/1`; stores them in
  `validation_findings` and transitions draft -> validated only when the
  errors list is empty — otherwise the mapping stays a draft **with its
  findings**, which is what the UI's per-field error display reads.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      mapping = %{
        field_rules: Ash.Changeset.get_attribute(changeset, :field_rules),
        observed_schema: Ash.Changeset.get_attribute(changeset, :observed_schema),
        target_resource: Ash.Changeset.get_attribute(changeset, :target_resource),
        direction: Ash.Changeset.get_attribute(changeset, :direction)
      }

      findings = AshMdm.Mapping.Validator.findings(mapping)

      status = if(findings.errors == [], do: :validated, else: :draft)

      changeset
      |> Ash.Changeset.force_change_attribute(:validation_findings, findings)
      |> Ash.Changeset.force_change_attribute(:status, status)
    end)
  end
end

defmodule AshMdm.Changes.Activate do
  @moduledoc """
  validated -> active, and the previously active version of the same
  identity tuple retires: activation supersedes, nothing is overwritten.

  The one-active partial unique index is the database's backstop; this
  change is the designed path (retire predecessor, then activate). Scoped
  to `organization_id` when the host's base supplies it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    # Retire predecessors BEFORE this row becomes active, otherwise the
    # one-active partial unique index sees two active rows for the tuple.
    |> Ash.Changeset.before_action(&retire_predecessors/1)
    |> Ash.Changeset.force_change_attribute(:status, :active)
  end

  defp retire_predecessors(changeset) do
    filters = [
      direction: Ash.Changeset.get_attribute(changeset, :direction),
      source: Ash.Changeset.get_attribute(changeset, :source),
      stream: Ash.Changeset.get_attribute(changeset, :stream),
      target_resource: Ash.Changeset.get_attribute(changeset, :target_resource),
      status: :active
    ]

    filters =
      case Ash.Changeset.get_attribute(changeset, :organization_id) do
        nil -> filters
        org -> Keyword.put(filters, :organization_id, org)
      end

    changeset.resource
    |> Ash.Query.filter(^filters)
    |> Ash.Query.filter(id != ^changeset.data.id)
    |> Ash.read!(tenant: changeset.tenant, authorize?: false)
    |> Enum.each(fn predecessor ->
      predecessor
      |> Ash.Changeset.for_update(:retire, %{})
      |> Ash.update!(authorize?: false)
    end)

    changeset
  end
end
