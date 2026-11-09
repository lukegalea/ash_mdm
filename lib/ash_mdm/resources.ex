# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Resources do
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
  # The macros' quotes ARE the deliverable: whole resources, macro-generated
  # on the host's base so the host's policies govern their actions natively
  # — the same posture as ash_discrete_business_events (ADR 0009 family).
  @moduledoc """
  The resource-macro entry points hosts use to instantiate ash_mdm's
  resources *on their own base*.

      defmodule MyApp.Mdm.Mapping do
        use Ash.Resource,
          domain: MyApp.Mdm,
          data_layer: AshPostgres.DataLayer

        use AshMdm.Resources, {:mapping, repo: MyApp.Repo, table: "mdm_mappings"}
      end

  **Resource macros, not concrete modules** — a host's grants, tenancy and
  audit govern the macro-generated actions natively, because the host module
  is the resource and the package only contributes the shape.

  ## `:mapping`

  One row per (tenant, direction, source, stream, target resource) **version**.
  See `AshMdm.Mapping`. Options:

    * `:repo`, `:table` — required; the macro owns the `postgres` block
      because it also owns the **one-active** partial unique index
      (`WHERE status = 'active'` on the identity tuple) — a database-level
      guarantee that only one version of a mapping can be live at a time.
    * `:tenant?` — pass `true` when the host's base supplies
      `organization_id` (a platform base with `tenant?: true`). Adds the
      column to the one-active index and scopes activation-supersedence to
      the tenant.

  ## `:attribute_assertion`

  One append-only row per statement that an attribute of a golden record has
  a value, with its origin. See `AshMdm.Assertions`. Options:

    * `:repo`, `:table` — required; the macro owns the `postgres` block.
    * `:tenant?` — pass `true` when the host's base supplies
      `organization_id`; it joins the lookup index.
    * `:sensitive_value?` — pass `true` when the golden's attributes are
      sensitive, such as a person's name and email.

  The macro ships no read policy. A host whose goldens are not visible to
  everyone must gate reads on the golden itself, or this table discloses
  what the golden's own policies hide.

  ## `:completeness_profile`

  One row per (golden resource, purpose) **version**: which attributes a
  golden needs for that purpose and why. See `AshMdm.Completeness`. Takes
  `:repo`, `:table` and `:tenant?` as `:mapping` does, for the same
  **one-active** index.

  ## `:attribute_gap`

  One rebuildable row per (golden, profile, attribute) holding the inputs of
  a completeness assessment: never a value. Its `gap_kind` calculation says,
  at read time, whether the requirement is met. Takes `:repo`, `:table` and
  `:tenant?`. Like assertions, it ships no read policy.

  ## `:match_rule_set`

  One row per version of the match rules for a golden resource: `rules`
  (scored by `AshMdm.Match`) and a `survivorship` policy (folded by
  `AshMdm.Survivorship`). `:draft` -> `:activate` -> `:retire`; activation
  retires the previously active set for the same `golden_resource` and
  refuses unknown survivorship strategies
  (`AshMdm.Validations.ValidSurvivorship`). `:draft` stamps `content_hash`
  over `rules` and `survivorship`. Options:

    * `:repo`, `:table` — required; the macro owns the `postgres` block.

  ## `:match_candidate`

  One row per (staged record, golden record) pair — identity `:one_pair` —
  with `score`, `explanation`, a host-resolved `band` and a `status`.
  The machine `:update` may set `:band` and the machine statuses but refuses
  `:confirmed`/`:rejected`, which are a person's acts on host-defined gated
  actions; `:record_verdict_ref` stamps `human_verdict_ref` afterwards.
  Takes no options and emits no `postgres` block: the host supplies the
  data layer config.
  """

  defmacro __using__(which)

  defmacro __using__({:mapping, opts}) do
    opts = Keyword.validate!(opts, [:repo, :table, tenant?: false])
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.fetch!(opts, :table)
    tenant? = Keyword.fetch!(opts, :tenant?)

    index_cols =
      if tenant?,
        do: [:organization_id, :direction, :source, :stream, :target_resource],
        else: [:direction, :source, :stream, :target_resource]

    index_name = :"#{table}_one_active"

    quote location: :keep do
      attributes do
        uuid_primary_key :id

        attribute :direction, :atom do
          allow_nil? false
          public? true
          constraints one_of: [:ingress, :egress]
        end

        attribute :source, :string do
          allow_nil? false
          public? true
          constraints max_length: 64
        end

        attribute :stream, :string do
          allow_nil? false
          public? true
          constraints max_length: 64
        end

        attribute :target_resource, :string do
          allow_nil? false
          public? true

          description "Module name of the golden entity, resolved against the host's `config :ash_mdm, :allowed_targets` allowlist; a name outside it fails validation."
        end

        attribute :field_rules, {:array, :map} do
          allow_nil? false
          public? true

          description "Ordered list of field rules; string-keyed JSON in the closed operator vocabulary of AshMdm.Mapping.Evaluator."
        end

        attribute :observed_schema, :map do
          public? true

          description "Field -> type/observed values, captured at proposal time; the basis for decode totality and required-path checks."
        end

        attribute :status, :atom do
          allow_nil? false
          public? true
          default :draft
          constraints one_of: [:draft, :validated, :active, :retired]
        end

        attribute :version, :integer do
          allow_nil? false
          public? true
          default 1
        end

        attribute :root_id, :uuid do
          public? true

          description "First version of this version chain; nil until the draft is persisted, then its own id."
        end

        attribute :supersedes_id, :uuid do
          public? true
          description "Immediate predecessor in the version chain, if any."
        end

        attribute :content_hash, :string do
          public? true

          description "SHA-256 over canonical field_rules JSON (AshMdm.Mapping.ContentHash). Batches pin this at open."
        end

        attribute :validation_findings, :map do
          public? true
          description "Last AshMdm.Mapping.Validator run: %{errors: [...], warnings: [...]}."
        end

        attribute :activation_note, :string do
          public? true
        end

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      actions do
        read :read do
          primary? true
        end

        create :draft do
          description "A new mapping version chain, starting at version 1, status draft."

          accept [
            :direction,
            :source,
            :stream,
            :target_resource,
            :field_rules,
            :observed_schema,
            :activation_note
          ]

          change {AshMdm.Changes.SetContentHash, fields: [:field_rules]}
          change AshMdm.Changes.OpenVersionChain
        end

        create :create_version do
          description """
          A person-edited successor of an existing version: copies nothing
          silently — the caller supplies the new field_rules; the chain
          linkage (root, version+1, supersedes) is derived from the
          predecessor. Status draft; the predecessor is untouched.
          """

          argument :from_mapping_id, :uuid do
            allow_nil? false
          end

          accept [
            :direction,
            :source,
            :stream,
            :target_resource,
            :field_rules,
            :observed_schema,
            :activation_note
          ]

          change {AshMdm.Changes.SetContentHash, fields: [:field_rules]}
          change AshMdm.Changes.LinkVersionChain
        end

        update :validate do
          description "Runs the validator set; draft -> validated only when the findings carry no errors."
          accept []
          validate attribute_equals(:status, :draft)
          # RunValidation reads the target resource's attribute list and
          # writes findings — introspection, not a data transform.
          require_atomic? false
          change AshMdm.Changes.RunValidation
        end

        update :activate do
          description """
          Person-gated at the host (policy); here: validated -> active, and
          the previously active version of the same identity tuple retires.
          """

          accept [:activation_note]
          validate attribute_equals(:status, :validated)
          # Activation supersedes: retiring the predecessor is a sibling-row
          # write that cannot be an in-row expression.
          require_atomic? false
          change AshMdm.Changes.Activate
        end

        update :retire do
          description "active -> retired. A retired version keeps its chain position forever."
          accept []
          validate attribute_equals(:status, :active)
          change set_attribute(:status, :retired)
        end
      end

      postgres do
        repo(unquote(repo))
        table unquote(table)

        custom_indexes do
          index(unquote(Macro.escape(index_cols)),
            unique: true,
            where: "status = 'active'",
            name: unquote(to_string(index_name))
          )
        end
      end
    end
  end

  defmacro __using__({:match_rule_set, opts}) do
    opts = Keyword.validate!(opts, [:repo, :table])
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.fetch!(opts, :table)

    quote location: :keep do
      attributes do
        uuid_primary_key :id

        attribute :golden_resource, :string do
          allow_nil? false
          public? true
          constraints max_length: 256
        end

        attribute :rules, {:array, :map} do
          allow_nil? false
          public? true
        end

        attribute :status, :atom do
          allow_nil? false
          public? true
          default :draft
          constraints one_of: [:draft, :active, :retired]
        end

        attribute :version, :integer do
          allow_nil? false
          public? true
          default 1
        end

        attribute :root_id, :uuid do
          public? true
        end

        attribute :supersedes_id, :uuid do
          public? true
        end

        attribute :survivorship, :map do
          public? true

          description "Survivorship policy as data: %{default, attributes, source_rank} per AshMdm.Survivorship."
        end

        attribute :content_hash, :string do
          public? true

          description "SHA-256 over canonical JSON of rules and survivorship (AshMdm.Mapping.ContentHash)."
        end

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      actions do
        read :read do
          primary? true
        end

        create :draft do
          accept [:golden_resource, :rules, :survivorship]
          change {AshMdm.Changes.SetContentHash, fields: [:rules, :survivorship]}
          change AshMdm.Changes.OpenVersionChain
        end

        create :create_version do
          description "A successor with new rules, such as a tuning proposal. The predecessor is untouched."

          argument :from_rule_set_id, :uuid do
            allow_nil? false
          end

          accept [:rules, :survivorship]
          change {AshMdm.Changes.SetContentHash, fields: [:rules, :survivorship]}

          change {AshMdm.Changes.LinkVersionChain,
                  argument: :from_rule_set_id, inherit: [:golden_resource]}
        end

        update :activate do
          accept []
          validate attribute_equals(:status, :draft)
          require_atomic? false
          # Unknown survivorship strategies are refused at activation, the
          # way unknown mapping operators are: a typo must not silently
          # merge with the default.
          validate AshMdm.Validations.ValidSurvivorship
          validate AshMdm.Validations.ValidMatchRules
          change AshMdm.Changes.ActivateRuleSet
        end

        update :retire do
          accept []
          validate attribute_equals(:status, :active)
          change set_attribute(:status, :retired)
        end
      end

      postgres do
        repo(unquote(repo))
        table unquote(table)
      end
    end
  end

  defmacro __using__({:match_candidate, _opts}) do
    quote location: :keep do
      attributes do
        uuid_primary_key :id

        attribute :staged_record_id, :uuid do
          allow_nil? false
          public? true
        end

        attribute :golden_resource, :string do
          allow_nil? false
          public? true
        end

        attribute :golden_id, :uuid do
          allow_nil? false
          public? true
        end

        attribute :score, :decimal do
          allow_nil? false
          public? true
        end

        attribute :explanation, :map do
          public? true
        end

        attribute :band, :atom do
          public? true
          constraints one_of: [:admit, :review, :omit]
          description "Resolved by the host's band table — never by this package."
        end

        attribute :status, :atom do
          allow_nil? false
          public? true
          default :pending
          constraints one_of: [:pending, :auto_merged, :confirmed, :rejected, :superseded]
        end

        attribute :human_verdict_ref, :map do
          public? true
        end

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      identities do
        identity :one_pair, [:staged_record_id, :golden_resource, :golden_id]
      end

      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [:staged_record_id, :golden_resource, :golden_id, :score, :explanation]
        end

        update :update do
          accept [:band, :status]

          # :confirmed/:rejected are a person's acts with their own gated
          # actions; the machine path (:update) may only set machine states —
          # banding writes :band, the pipeline writes :auto_merged/:superseded.
          validate attribute_does_not_equal(:status, :confirmed), where: [changing(:status)]
          validate attribute_does_not_equal(:status, :rejected), where: [changing(:status)]
        end

        update :record_verdict_ref do
          description "Stamps the verdict/judgment pointers after a gated decision committed."
          accept [:human_verdict_ref]
        end
      end
    end
  end

  defmacro __using__({:attribute_assertion, opts}) do
    opts = Keyword.validate!(opts, [:repo, :table, tenant?: false, sensitive_value?: false])
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.fetch!(opts, :table)
    tenant? = Keyword.fetch!(opts, :tenant?)
    sensitive_value? = Keyword.fetch!(opts, :sensitive_value?)
    origin_kinds = AshMdm.Assertions.origin_kinds()

    index_cols =
      if tenant?,
        do: [:organization_id, :golden_resource, :golden_id, :attribute],
        else: [:golden_resource, :golden_id, :attribute]

    index_name = "#{table}_statements_of"

    quote location: :keep do
      attributes do
        uuid_primary_key :id

        attribute :golden_resource, :string do
          allow_nil? false
          public? true
          constraints max_length: 256
        end

        attribute :golden_id, :uuid do
          allow_nil? false
          public? true

          description "The golden this statement is about. Deliberately no foreign key: a host's golden may live in a view it cannot reference."
        end

        attribute :attribute, :string do
          allow_nil? false
          public? true
          constraints max_length: 128
        end

        attribute :value, :map do
          public? true
          sensitive? unquote(sensitive_value?)

          description "The value, wrapped (AshMdm.Assertions.wrap_value/1). Nil only on a retraction."
        end

        attribute :origin_kind, :atom do
          allow_nil? false
          public? true
          constraints one_of: unquote(origin_kinds)
        end

        attribute :origin_ref, :map do
          allow_nil? false
          public? true

          description "What exactly said this: a mapping and landing, a decision version and its rules, an observation, a person's verdict."
        end

        attribute :source, :string do
          allow_nil? false
          public? true
          constraints max_length: 64

          description "The named source a survivorship source_rank compares."
        end

        attribute :band, :atom do
          public? true
          constraints one_of: [:admit, :review, :omit]

          description "Nil when no band applies. Only nil and :admit compete in the fold."
        end

        attribute :confidence, :decimal do
          public? true
          constraints min: 0, max: 1
        end

        attribute :observed_at, :utc_datetime_usec do
          allow_nil? false
          public? true
          description "When the origin said it, not when this row was written."
        end

        attribute :valid_until, :utc_datetime_usec do
          public? true
        end

        attribute :retracts_id, :uuid do
          public? true
          description "On a retraction, the assertion it withdraws."
        end

        attribute :content_digest, :string do
          allow_nil? false
          public? false
          description "Identity of the statement's content, so a retried write is a no-op."
        end

        create_timestamp :inserted_at
      end

      identities do
        identity :one_statement, [:content_digest]
      end

      actions do
        read :read do
          primary? true
        end

        create :assert do
          description """
          Records one statement. There is no update: a correction is a new
          statement, a withdrawal is a retraction. Re-asserting identical
          content changes nothing.
          """

          accept [
            :golden_resource,
            :golden_id,
            :attribute,
            :origin_kind,
            :origin_ref,
            :source,
            :band,
            :confidence,
            :observed_at,
            :valid_until,
            :retracts_id
          ]

          argument :value, :term do
            sensitive? unquote(sensitive_value?)
          end

          upsert? true
          upsert_identity :one_statement
          upsert_fields []

          validate AshMdm.Validations.ValidAssertion
          change AshMdm.Changes.SealAssertion
        end

        destroy :erase do
          description "Removes a statement for a host's erasure path. Never part of ordinary stewardship."
        end
      end

      postgres do
        repo(unquote(repo))
        table unquote(table)

        custom_indexes do
          index(unquote(Macro.escape(index_cols)), name: unquote(index_name))
        end
      end
    end
  end

  defmacro __using__({:completeness_profile, opts}) do
    opts = Keyword.validate!(opts, [:repo, :table, tenant?: false])
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.fetch!(opts, :table)
    tenant? = Keyword.fetch!(opts, :tenant?)

    index_cols =
      if tenant?,
        do: [:organization_id, :golden_resource, :purpose],
        else: [:golden_resource, :purpose]

    index_name = "#{table}_one_active"

    quote location: :keep do
      attributes do
        uuid_primary_key :id

        attribute :golden_resource, :string do
          allow_nil? false
          public? true
          constraints max_length: 256
        end

        attribute :purpose, :string do
          allow_nil? false
          public? true
          constraints max_length: 64
          description "What the golden is complete for. A host's own vocabulary."
        end

        attribute :requirements, {:array, :map} do
          allow_nil? false
          public? true
          description "One string-keyed entry per attribute; see AshMdm.Completeness."
        end

        attribute :status, :atom do
          allow_nil? false
          public? true
          default :draft
          constraints one_of: [:draft, :validated, :active, :retired]
        end

        attribute :version, :integer do
          allow_nil? false
          public? true
          default 1
        end

        attribute :root_id, :uuid do
          public? true
        end

        attribute :supersedes_id, :uuid do
          public? true
        end

        attribute :content_hash, :string do
          public? true
        end

        attribute :validation_findings, :map do
          public? true
        end

        attribute :activation_note, :string do
          public? true
        end

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      actions do
        read :read do
          primary? true
        end

        create :draft do
          accept [:golden_resource, :purpose, :requirements, :activation_note]
          change {AshMdm.Changes.SetContentHash, fields: [:requirements]}
          change AshMdm.Changes.OpenVersionChain
        end

        create :create_version do
          description "A successor of an existing version. The predecessor is untouched."

          argument :from_profile_id, :uuid do
            allow_nil? false
          end

          accept [:requirements, :activation_note]
          change {AshMdm.Changes.SetContentHash, fields: [:requirements]}

          change {AshMdm.Changes.LinkVersionChain,
                  argument: :from_profile_id, inherit: [:golden_resource, :purpose]}
        end

        update :validate do
          description "Runs the validator; draft -> validated only when there are no errors."
          accept []
          validate attribute_equals(:status, :draft)
          require_atomic? false
          change AshMdm.Changes.RunCompletenessValidation
        end

        update :activate do
          description "Person-gated at the host; validated -> active, retiring the predecessor."
          accept [:activation_note]
          validate attribute_equals(:status, :validated)
          require_atomic? false
          change {AshMdm.Changes.Activate, identity: [:golden_resource, :purpose]}
        end

        update :retire do
          accept []
          validate attribute_equals(:status, :active)
          change set_attribute(:status, :retired)
        end
      end

      postgres do
        repo(unquote(repo))
        table unquote(table)

        custom_indexes do
          index(unquote(Macro.escape(index_cols)),
            unique: true,
            where: "status = 'active'",
            name: unquote(index_name)
          )
        end
      end
    end
  end

  defmacro __using__({:attribute_gap, opts}) do
    opts = Keyword.validate!(opts, [:repo, :table, tenant?: false])
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.fetch!(opts, :table)
    tenant? = Keyword.fetch!(opts, :tenant?)
    gap_kinds = AshMdm.Completeness.kinds()

    index_cols =
      if tenant?,
        do: [:organization_id, :golden_resource, :golden_id],
        else: [:golden_resource, :golden_id]

    index_name = "#{table}_of_golden"
    input = ~w(max_age_days accepted_origins has_value standing_origin observed_at valid_until)a

    written =
      input ++ [:assertion_id, :pending_count, :because, :material, :profile_version, :purpose]

    quote location: :keep do
      attributes do
        uuid_primary_key :id

        attribute :golden_resource, :string do
          allow_nil? false
          public? true
          constraints max_length: 256
        end

        attribute :golden_id, :uuid do
          allow_nil? false
          public? true
        end

        attribute :profile_id, :uuid do
          allow_nil? false
          public? true
        end

        attribute :profile_version, :integer do
          allow_nil? false
          public? true
        end

        attribute :purpose, :string do
          allow_nil? false
          public? true
          constraints max_length: 64
        end

        attribute :attribute, :string do
          allow_nil? false
          public? true
          constraints max_length: 128
        end

        attribute :because, :string do
          allow_nil? false
          public? true
        end

        attribute :material, :boolean do
          allow_nil? false
          public? true
          default false
        end

        attribute :max_age_days, :integer do
          public? true
        end

        attribute :accepted_origins, {:array, :string} do
          public? true
        end

        attribute :has_value, :boolean do
          allow_nil? false
          public? true
          default false
        end

        attribute :standing_origin, :string do
          public? true
        end

        attribute :observed_at, :utc_datetime_usec do
          public? true
        end

        attribute :valid_until, :utc_datetime_usec do
          public? true
        end

        attribute :assertion_id, :uuid do
          public? true
          description "Nil when the standing value is held outside the assertion table."
        end

        attribute :pending_count, :integer do
          allow_nil? false
          public? true
          default 0
          description "Statements about this attribute waiting on a person."
        end

        update_timestamp :refreshed_at
      end

      calculations do
        calculate :gap_kind, :atom, AshMdm.Completeness.GapKind do
          public? true
          constraints one_of: unquote(gap_kinds)
        end
      end

      identities do
        identity :one_requirement, [:golden_resource, :golden_id, :profile_id, :attribute]
      end

      actions do
        read :read do
          primary? true
        end

        create :project do
          description "Writes one assessment's inputs. Rebuildable; carries no value."

          accept unquote([:golden_resource, :golden_id, :profile_id, :attribute | written])
          upsert? true
          upsert_identity :one_requirement
          upsert_fields unquote(written)
        end

        destroy :clear do
          description "Removes a projected row, for a rebuild."
        end
      end

      postgres do
        repo(unquote(repo))
        table unquote(table)

        custom_indexes do
          index(unquote(Macro.escape(index_cols)), name: unquote(index_name))
        end
      end
    end
  end

  defmacro __using__(other) do
    raise ArgumentError, "AshMdm.Resources: unknown resource #{inspect(other)}"
  end
end
