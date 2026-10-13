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
    resource AshMdm.Fixtures.MatchCandidate
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

defmodule AshMdm.Fixtures.MatchRuleSet do
  @moduledoc "The macro-generated MatchRuleSet on the suite's own base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:match_rule_set, repo: AshMdm.Test.Repo, table: "mdm_match_rule_sets"}
end

defmodule AshMdm.Fixtures.MatchCandidate do
  @moduledoc "The macro-generated MatchCandidate on the suite's own base."

  use Ash.Resource,
    domain: AshMdm.Fixtures,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:match_candidate, []}
end
