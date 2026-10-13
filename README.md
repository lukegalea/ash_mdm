# AshMdm

Master data management machinery for Ash: versioned schema mappings as data,
deterministic entity resolution with rules-as-data, survivorship and
non-destructive merge over golden records.

`ash_mdm` ships **resource macros**, not concrete resources — the host
instantiates them on its own platform base and keeps its own policies, the
same pattern as `ash_discrete_business_events`. It never depends on any host
application.

<!-- moduledoc -->

## Status

Skeleton. The slices land in order: Mapping (ingress/egress, operator
vocabulary, validators), landing + import batches, blocking + scoring,
banding + stewardship, survivorship + merge, egress, data-quality rules,
mapping proposals.

## Licence

MIT — see [LICENSE](LICENSE).
<!-- /moduledoc -->
