# Contribution Workflow

This repo (and its sibling `prem-league-tracker-fe`) follow GitFlow branching plus a mandatory GitHub-Issues-driven process. This applies to every task, not just features.

## Branches

- `master` — production. Protected (PR required, no direct pushes, no force-push, no deletion). Merges here trigger the production deploy pipeline.
- `develop` — integration branch. Protected (PR required).
- `staging` — pre-production/QA branch, sits between `develop` and `master`. Used to validate a batch of changes before promoting to `master`.
- `feature/<short-task-slug>` — one per task/issue, branched from `develop`, merged back into `develop` via PR.

Promotion flow: `feature/*` → PR into `develop` → (periodically) `develop` → `staging` → `master`.

## Every task starts with an Issue

1. **Before starting work**, open a GitHub Issue describing the task:
   - Clear title.
   - Thoroughly detailed requirements — what needs to exist when done, edge cases, constraints.
   - An explicit **Definition of Done** section with checkable criteria.
2. Branch `feature/<slug>` from `develop`. Reference the issue number in commit messages (e.g. `Refs #12` or `Closes #12`).
3. As work progresses, **comment on the issue** describing what phase was completed and what's next. Don't do the work silently and report only at the end — the issue is the audit trail.
4. Open a PR into `develop` once the Definition of Done is met, referencing/closing the issue.

This is a hard requirement: every change should be traceable to an issue, a branch, and a PR, with progress visible in the issue's comment history — not only in chat or commit messages.

## Branch protection caveat

Classic GitHub branch protection (and rulesets) require GitHub Pro/Team for private repositories. This repo is public specifically so free-tier branch protection is available on `master` and `develop`. If that tradeoff changes, protection settings will need to be revisited.
