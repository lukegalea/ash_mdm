# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Changes.SetContentHash do
  @moduledoc """
  Stamps `content_hash` from the canonical JSON of the attributes named by
  the required `fields:` option.

  One field hashes that attribute's bare value (a mapping's `field_rules`);
  several hash a map keyed by field name (a rule set's `rules` and
  `survivorship`). A field the resource does not have raises: a hash of
  nothing would be a valid-looking constant.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    case opts[:fields] do
      [_ | _] = fields ->
        if Enum.all?(fields, &is_atom/1),
          do: {:ok, opts},
          else: {:error, "fields must be a list of attribute names"}

      _ ->
        {:error, "fields is required: the attributes the content hash covers"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    fields = opts[:fields]

    for field <- fields, is_nil(Ash.Resource.Info.attribute(changeset.resource, field)) do
      raise ArgumentError,
            "#{inspect(changeset.resource)} has no attribute #{inspect(field)} to content-hash"
    end

    Ash.Changeset.before_action(changeset, fn changeset ->
      hash = AshMdm.Mapping.ContentHash.hash!(content(changeset, fields))

      Ash.Changeset.force_change_attribute(changeset, :content_hash, hash)
    end)
  end

  defp content(changeset, [field]), do: Ash.Changeset.get_attribute(changeset, field)

  defp content(changeset, fields),
    do: Map.new(fields, &{&1, Ash.Changeset.get_attribute(changeset, &1)})
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
  Derives the version-chain linkage from the predecessor named by the
  argument in the `:argument` option (default `:from_mapping_id`):
  `root_id`, `version + 1`, `supersedes_id`. The predecessor is read in the
  changeset's tenant and is untouched — nothing is overwritten, ever. One that
  cannot be found there is a refusal on that argument.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    argument = opts[:argument] || :from_mapping_id

    Ash.Changeset.before_action(changeset, fn changeset ->
      id = Ash.Changeset.get_argument(changeset, argument)

      case Ash.get(changeset.resource, id, tenant: changeset.tenant, authorize?: false) do
        {:ok, predecessor} ->
          link(changeset, predecessor, opts[:inherit])

        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} ->
          Ash.Changeset.add_error(changeset, field: argument, message: "no such version")

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp link(changeset, predecessor, inherit) do
    inherit
    |> List.wrap()
    |> Enum.reduce(changeset, fn attribute, changeset ->
      Ash.Changeset.force_change_attribute(
        changeset,
        attribute,
        Map.fetch!(predecessor, attribute)
      )
    end)
    |> Ash.Changeset.force_change_attribute(:supersedes_id, predecessor.id)
    |> Ash.Changeset.force_change_attribute(:root_id, predecessor.root_id || predecessor.id)
    |> Ash.Changeset.force_change_attribute(:version, (predecessor.version || 1) + 1)
    |> Ash.Changeset.force_change_attribute(:status, :draft)
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

  The status is checked again in the write itself, so a stale copy of a row
  that has moved on since it was read is refused and rolls back the retiring.
  """

  use Ash.Resource.Change

  require Ash.Expr

  @mapping_identity [:direction, :source, :stream, :target_resource]

  @impl true
  def change(changeset, opts, _context) do
    identity = opts[:identity] || @mapping_identity

    changeset
    # Retire predecessors BEFORE this row becomes active, otherwise the
    # one-active partial unique index sees two active rows for the tuple.
    |> Ash.Changeset.before_action(&retire_predecessors(&1, identity))
    |> Ash.Changeset.filter(Ash.Expr.expr(status == :validated))
    |> Ash.Changeset.force_change_attribute(:status, :active)
  end

  defp retire_predecessors(changeset, identity) do
    filters =
      Enum.map(identity, &{&1, Ash.Changeset.get_attribute(changeset, &1)}) ++ [status: :active]

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

defmodule AshMdm.Changes.ActivateRuleSet do
  @moduledoc """
  draft -> active for a MatchRuleSet, retiring the previously active set
  for the same golden resource (same supersede semantics as Mapping).
  """

  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      resource = Ash.Changeset.get_attribute(changeset, :golden_resource)

      changeset.resource
      |> Ash.Query.filter(
        golden_resource == ^resource and status == :active and id != ^changeset.data.id
      )
      |> Ash.read!(tenant: changeset.tenant, authorize?: false)
      |> Enum.each(fn predecessor ->
        predecessor
        |> Ash.Changeset.for_update(:retire, %{})
        |> Ash.update!(authorize?: false)
      end)

      Ash.Changeset.force_change_attribute(changeset, :status, :active)
    end)
  end
end

defmodule AshMdm.Changes.SealAssertion do
  @moduledoc """
  Wraps an assertion's value for storage and stamps the digest of its
  content, so writing the same statement twice (a retried job) is one row.
  """

  use Ash.Resource.Change

  @sealed ~w(golden_resource golden_id attribute origin_kind origin_ref source band confidence observed_at valid_until retracts_id)a

  @impl true
  def change(%{valid?: false} = changeset, _opts, _context), do: changeset

  def change(changeset, _opts, _context) do
    value =
      case Ash.Changeset.get_argument(changeset, :value) do
        nil -> nil
        value -> AshMdm.Assertions.wrap_value(value)
      end

    content =
      @sealed
      |> Map.new(&{&1, Ash.Changeset.get_attribute(changeset, &1)})
      |> Map.put(:value, value)

    changeset
    |> Ash.Changeset.force_change_attribute(:value, value)
    |> Ash.Changeset.force_change_attribute(
      :content_digest,
      AshMdm.Mapping.ContentHash.hash!(content)
    )
  end
end

defmodule AshMdm.Changes.RunCompletenessValidation do
  @moduledoc """
  Runs `AshMdm.Completeness.Validator.findings/1`: draft -> validated only
  when there are no errors, otherwise the profile stays a draft with its
  findings.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      findings =
        AshMdm.Completeness.Validator.findings(%{
          golden_resource: Ash.Changeset.get_attribute(changeset, :golden_resource),
          requirements: Ash.Changeset.get_attribute(changeset, :requirements)
        })

      status = if(findings.errors == [], do: :validated, else: :draft)

      changeset
      |> Ash.Changeset.force_change_attribute(:validation_findings, findings)
      |> Ash.Changeset.force_change_attribute(:status, status)
    end)
  end
end

defmodule AshMdm.Changes.RunResolverValidation do
  @moduledoc """
  Runs `AshMdm.Resolution.Validator.findings/1`: draft -> validated only when
  there are no errors, otherwise the resolver stays a draft with its findings.
  The status is checked again in the write itself, so a stale copy of a draft
  cannot pull a resolver that has since been activated back out of service.
  """

  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status == :draft))
    |> Ash.Changeset.before_action(fn changeset ->
      findings =
        AshMdm.Resolution.Validator.findings(
          Map.new(
            ~w(golden_resource kind produces requires cost_rank reference)a,
            &{&1, Ash.Changeset.get_attribute(changeset, &1)}
          )
        )

      status = if(findings.errors == [], do: :validated, else: :draft)

      changeset
      |> Ash.Changeset.force_change_attribute(:validation_findings, findings)
      |> Ash.Changeset.force_change_attribute(:status, status)
    end)
  end
end

defmodule AshMdm.Changes.OrderGoldenPair do
  @moduledoc """
  Puts a golden pair in canonical order, `golden_id < other_golden_id`, so
  (a, b) and (b, a) are the same candidate to the unique index.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    a = Ash.Changeset.get_attribute(changeset, :golden_id)
    b = Ash.Changeset.get_attribute(changeset, :other_golden_id)

    if is_binary(a) and is_binary(b) and a > b do
      changeset
      |> Ash.Changeset.force_change_attribute(:golden_id, b)
      |> Ash.Changeset.force_change_attribute(:other_golden_id, a)
    else
      changeset
    end
  end
end
