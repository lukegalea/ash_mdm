# ash_mdm

**Master data management for Ash: mappings as versioned data, deterministic
matching, and a steward's queue — with no deploy between "new customer
schema" and "running pipeline".**

`ash_mdm` ships **resource macros**, not concrete resources: a host
instantiates them on its own platform base — host policies, tenancy and
audit govern natively, and the package never assumes an actor model.

```elixir
use AshEnterprise.Platform.Resource, domain: MyApp.Mdm, ownership: :organization_owned

use AshMdm.Resources, {:mapping, repo: MyApp.Repo, table: "mdm_mappings", tenant?: true}
```

## What's in the box

| Piece | Resource | One line |
|---|---|---|
| Mappings | `{:mapping, …}` | Versioned schema mappings (ingress + egress); draft → validate → activate; activation supersedes and nothing is overwritten |
| Match rule sets | `{:match_rule_set, …}` | Deterministic matching as data — exact/fuzzy rules with weights, survivorship declared per attribute, unknown strategies refused at activation |
| Match candidates | `{:match_candidate, …}` | (staged, golden) pairs with score and per-rule explanation, banded `admit/review/omit` by the host's own band table |

Supporting modules: `AshMdm.Mapping.Evaluator` (the rule fold),
`AshMdm.Mapping.Validator` (the activate gate: total accounting with
egress-aware path/target semantics, decode totality + injectivity, required
paths, cast compatibility), `AshMdm.Mapping.ContentHash` (SHA-256 over the
canonical rule JSON), `AshMdm.Changes` (content hash, version chain, run
validation, activation), `AshMdm.Validations.ValidSurvivorship` (declared
survivorship must name real strategies), `AshMdm.Survivorship` (the
survivorship fold), `AshMdm.Match` (the match scorer).

## The no-deploy guarantee

Onboarding a new customer schema is **data**: land their source records,
author a mapping version, validate it, activate it. The only things that
require a release are a new third-party *adapter* (code) or a new canonical
*entity* (migration) — mappings are data, and the evaluator reads them at
runtime.

## Fail-closed by construction

- Mapping **targets** resolve against a host allowlist
  (`config :ash_mdm, :allowed_targets`) — a mapping row can only point at
  declared golden resources.
- Rule **operators** come from a closed vocabulary; unknown ops refuse
  validation.
- **Activation** retires the predecessor and is audited like every other
  write. Person-gating the activation (and the steward's confirm/reject) is
  host policy — the package declares no policies of its own.
- The machine `:update` on candidates cannot write person states
  (`:confirmed`/`:rejected` ride their own gated actions).

## The steward UI

The host ships a full import → resolve → review flow at `/app/mdm/*`.

![The import wizard's mapping step: the CSV's columns mapped onto the golden
Person record by the AI proposal, with the active mappings listed as
data.](docs/screenshots/mdm-import-mapping.png)

Mapping a new customer schema is a draft the machine proposes and a person
activates — never a release. Total accounting is the activation gate: every
golden attribute is mapped, or explicitly unmapped with a because.

![The steward queue's side-by-side diff: the staged record's values against
the golden's, with the survivorship winner highlighted — the golden's own
values beat a fold.](docs/screenshots/mdm-steward-queue.png)

Low-confidence matches wait here as person-gated decisions: **confirm**
merges the staged record into the golden, **reject** keeps it a record of
its own, and **unsure** records the verdict and leaves the candidate open
for a senior steward.

![The golden record surface after the import and the steward's confirm:
the imported people are goldens of their own, and the confirmed match
folded into its survivor.](docs/screenshots/mdm-golden-lineage.png)

Merge lineage is data (`merged`/`master_id` plus the `SourceIdentity`
XREF), so "where did this golden come from" is one query. Review-banded
matches run the enterprise host's `mdm.steward_review` BPMN process
(forkable per tenant), and banding itself is a DMN decision table; the
import's land/stage/match stages are host code today. These are the
host's screens — the package ships the engine, not the UI.

<!-- moduledoc -->

## Status

`0.1.x` — the MDM-0..6 build ([ADR 0050](https://github.com/lukegalea/ash_enterprise)
in the enterprise host). Deterministic + fuzzy scoring banded by the host's
DMN table; probabilistic linkage stays an escape hatch (see the host plan's
Splink note).

## License

MIT — see `LICENSES/` and `REUSE.toml`.
