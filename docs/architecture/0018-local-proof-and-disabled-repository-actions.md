# ADR 0018 — Local Proof and Disabled Repository Actions

- Status: Accepted
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit instruction that GitHub Actions should not do anything
- Founding clauses refined: PRD 25.3–25.4, 31 Milestone 0, 34, and 39
- Supersedes: the hosted-CI clauses of ADR 0002

## Context and evidence

Open Scribe's current proof requires pinned Rust, WASM, Bun, Swift, and Xcode tools on macOS. A GitHub-hosted job added a second, provider-owned availability boundary without adding signing, deployment, capture, recovery, or release evidence. The job did not start, while the exact candidate completed the full local gate and independent adversarial review. Repository proof must describe tested product behavior, not the availability or billing state of a hosted runner.

## Decision

- GitHub Actions is disabled in repository settings and no workflow is checked in.
- Branch protection does not require a hosted status check.
- A pull-request candidate is admitted only after its exact checkout passes the narrow relevant gate and the complete enclosing gate, `git diff --check`, and an independent review of the same candidate tree.
- The merge receipt binds candidate SHA/tree, commands, named green receipts, reviewer verdict, PR identity, merge commit, and mainline ancestry.
- Toolchain pins remain checked source. A toolchain change must be reviewed with its lockfiles and must re-run the complete local gate.
- Signing, notarization, packaging, publication, and deployment remain separate proof planes. Any future protected release transaction runs outside GitHub Actions and cannot weaken artifact or publication gates.

## Alternatives

A required hosted job can detect a different environment, but it also makes provider availability a merge authority and is expressly outside the chosen operating model. An unreviewed local-only command would be too weak because it would not bind the result to a candidate tree or provide adversarial inspection. Treating a failed-to-start job as a product failure would confuse provider state with repository behavior.

## Consequences

Pull requests do not display a hosted compatibility result. The repository instead carries exact, reproducible commands and exclusions, and the merge record must preserve their output and candidate identity. Compatibility with an untested GitHub runner is unknown and must not be claimed. Repository Actions cannot consume secrets, publish artifacts, or mutate external systems because it is disabled.

## Security and privacy

No repository workflow receives code, secrets, signing identities, Cloudflare credentials, media, or user data. Local proof uses the operator-controlled checkout. Independent review remains read-only. Protected external actions still require their own explicit authority, least-privilege credentials, artifact identity, and readback.

## Migration and rollback

Delete the checked-in workflow, remove it from scaffold requirements, disable Actions in repository settings, and remove required hosted checks from branch protection. Preserve conversation-resolution, admin-enforcement, and force-push/deletion protections. Re-enabling Actions would require a new approved ADR and explicit operator instruction; it is not a routine rollback.

## Proof

Read back repository Actions as disabled and main protection with no required status checks. On the exact candidate, run `./script/check.sh --scaffold`, the complete relevant product gate, and `git diff --check`; record every named receipt and the independent review. After merge, prove the candidate is an ancestor of main and bind the main SHA/tree. None of this proves capture, recovery, signing, notarization, deployment, distribution, or release.
