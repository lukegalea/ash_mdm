# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Fixtures do
  @moduledoc """
  The suite's fixture domain and resources: the package's real resource is
  macro-generated on this suite's own base — the same posture a host takes.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshMdm.Fixtures.Mapping
    resource AshMdm.Fixtures.Person
    resource AshMdm.Fixtures.MatchRuleSet
    resource AshMdm.Fixtures.TenantMatchRuleSet
    resource AshMdm.Fixtures.MatchCandidate
    resource AshMdm.Fixtures.AttributeAssertion
    resource AshMdm.Fixtures.SensitiveAttributeAssertion
    resource AshMdm.Fixtures.CompletenessProfile
    resource AshMdm.Fixtures.AttributeGap
    resource AshMdm.Fixtures.Resolver
    resource AshMdm.Fixtures.TenantResolver
  end
end

defmodule AshMdm.Fixtures.Person do
  @moduledoc "A stand-in golden entity for validator/evaluator tests."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "fixture_people"
    repo(AshMdm.Test.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, public?: true
    attribute :email, :ci_string, public?: true
    attribute :tier, :string, public?: true
    attribute :joined_on, :date, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :email, :tier, :joined_on]
    end

    update :update do
      accept [:name, :email, :tier, :joined_on]
    end
  end
end

defmodule AshMdm.Fixtures.Mapping do
  @moduledoc """
  The macro-generated Mapping on the suite's own base. Contributing only the
  base is the point: the macro supplies attributes, actions and the
  one-active partial unique index; the host would add its policies here.
  """

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources,
      {:mapping, repo: AshMdm.Test.Repo, table: "mdm_mappings", tenant?: false}
end

defmodule AshMdm.Fixtures.AttributeAssertion do
  @moduledoc "The macro-generated AttributeAssertion on the suite's own base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources,
      {:attribute_assertion, repo: AshMdm.Test.Repo, table: "mdm_attribute_assertions"}
end

defmodule AshMdm.Fixtures.DigestSecret do
  @moduledoc "The key a sensitive fixture's content digest is keyed by."

  def fetch, do: "fixture-digest-secret"
end

defmodule AshMdm.Fixtures.SensitiveAttributeAssertion do
  @moduledoc "The attribute assertion macro with `sensitive_value?: true`."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources,
      {:attribute_assertion,
       repo: AshMdm.Test.Repo,
       table: "mdm_sensitive_attribute_assertions",
       sensitive_value?: true,
       digest_secret: {AshMdm.Fixtures.DigestSecret, :fetch, []}}
end

defmodule AshMdm.Fixtures.CompletenessProfile do
  @moduledoc "The macro-generated CompletenessProfile on the suite's own base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources,
      {:completeness_profile, repo: AshMdm.Test.Repo, table: "mdm_completeness_profiles"}
end

defmodule AshMdm.Fixtures.AttributeGap do
  @moduledoc "The macro-generated AttributeGap on the suite's own base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:attribute_gap, repo: AshMdm.Test.Repo, table: "mdm_attribute_gaps"}
end

defmodule AshMdm.Fixtures.MatchRuleSet do
  @moduledoc "The macro-generated MatchRuleSet on the suite's own base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:match_rule_set, repo: AshMdm.Test.Repo, table: "mdm_match_rule_sets"}
end

defmodule AshMdm.Fixtures.TenantMatchRuleSet do
  @moduledoc "The macro-generated MatchRuleSet on a global-tenancy base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources,
      {:match_rule_set,
       repo: AshMdm.Test.Repo, table: "mdm_tenant_match_rule_sets", tenant?: true}

  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end

  attributes do
    attribute :organization_id, :uuid do
      allow_nil? false
      public? true
    end
  end
end

defmodule AshMdm.Fixtures.MatchCandidate do
  @moduledoc "The macro-generated MatchCandidate on the suite's own base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:match_candidate, []}

  # The :match_candidate macro emits no postgres block; the host supplies it.
  postgres do
    table "mdm_match_candidates"
    repo(AshMdm.Test.Repo)

    identity_wheres_to_sql(one_golden_pair: "other_golden_id IS NOT NULL")

    check_constraints do
      check_constraint(:other_golden_id, "exactly_one_pairing",
        check: "(staged_record_id IS NULL) <> (other_golden_id IS NULL)",
        message: "exactly one of staged_record_id and other_golden_id must be set"
      )
    end
  end
end

defmodule AshMdm.Fixtures.Resolver do
  @moduledoc "The macro-generated Resolver on the suite's own base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:resolver, repo: AshMdm.Test.Repo, table: "mdm_resolvers"}
end

defmodule AshMdm.Fixtures.TenantResolver do
  @moduledoc "The macro-generated Resolver on a base with attribute multitenancy."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources,
      {:resolver, repo: AshMdm.Test.Repo, table: "mdm_tenant_resolvers", tenant?: true}

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  attributes do
    attribute :organization_id, :uuid do
      allow_nil? false
      public? true
    end
  end
end
