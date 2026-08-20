# Open Scribe Authority Layers

> **Budget:** 400 words. Higher layers constrain lower layers; fix divergence at the lowest responsible layer.

## Upstream contract

`docs/product/FOUNDING_PRD.md` is the founding product and architecture source of truth. `NORTH_STAR.md`, `ANCHOR.md`, and `ARCHITECTURE.md` are compact projections for regrounding. They may clarify but may not silently contradict it.

An ADR can supersede a founding architecture choice only when it names the affected PRD clause, evidence, approver, migration impact, and rollback. Product-purpose or invariant changes require an explicitly approved PRD revision.

## Authority stack

| Layer | Owns | Primary source |
|---|---|---|
| L0 — Founding contract | product requirements, milestone scope, founding architecture | `docs/product/FOUNDING_PRD.md` |
| L0P — Purpose projection | mission, target outcome, success, non-goals | `NORTH_STAR.md` |
| L1 — Invariants | non-negotiable properties and prohibitions | `ANCHOR.md` |
| L2 — Architecture | current boundaries, intended structure, approved choices | `ARCHITECTURE.md`, approved ADRs |
| L3 — Operations | authorized actions, preconditions, proof, rollback | `ACTOR.md`, `AGENTS.md` |
| L4 — Implementation | code, tests, configuration, migrations | repository implementation |
| L5 — Artifact/runtime | built app/site and observed local behavior | exact local artifact receipts |
| L6 — Release/live | signed distribution, deployment, authenticated readback | release and live-verification receipts |

Lower evidence cannot prove a higher plane. A structure check does not prove a build; a build does not prove capture; capture does not prove recovery; source does not prove deployment; deployment does not prove the public artifact.

## Sidecars

- `NUANCE.md` records only reproduced counterintuitive facts. It can challenge assumptions but grants no permission.
- `SOUL.md` preserves authentic posture and metaphor. It changes attention, never authority.

## Classification test

For every material change, state:

1. Which claim changes, and which layer owns it?
2. Which higher source constrains it?
3. What lower artifact realizes it?
4. Which exact proof plane will show agreement?
5. Is the change a projection update, implementation, or explicit supersession?

When sources disagree, expose the conflict and stop if it is material.
