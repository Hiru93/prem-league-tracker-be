# Roadmap

The live, authoritative roadmap is the **"Prem League Tracker Roadmap"** GitHub Project board (Projects v2), linked to both `prem-league-tracker-be` and `prem-league-tracker-fe`:

**https://github.com/users/Hiru93/projects/2**

This file explains the plan; the board shows current, real-time status. If the two ever disagree, trust the board and update this file to match.

## Why a Project board, not a markdown file

Per `docs/workflow.md`, every task is tracked as a GitHub Issue. A Project board lets those issues (from both repos) be viewed together, grouped by phase, with status that updates automatically as issues move and close — no separate document to keep in sync by hand.

## Phases

| Phase | Covers |
|---|---|
| **0 — Foundations** | Repo setup, GitFlow branches, branch protection, initial documentation set, CI/CD skeleton, roadmap tracking itself. |
| **1 — Backend Domain & Data Model** | Prisma schema, Postgres/Neon wiring, core entities (Stage, Player, StagePlacement, Decklist, DecklistEntry). |
| **2 — Backend Integrations** | melee.gg ingestion (stages, placements, decklists, players) and Scryfall card resolution/caching. |
| **3 — Backend API & Scoring** | League scoring computation, standings aggregation, the REST API matching `backend-api-contract-technical.md`. |
| **4 — Frontend Build-out** | League standings, tournament-stage, decklist, and player-profile screens; RTK Query wiring against the live API. |
| **5 — Containerization** | Dockerfiles + `docker-compose.yml` for both repos (see `docs/containerization-technical.md` and projectBriefing.md §7), local full-stack integration setup. |
| **6 — Integration & Deployment Hardening** | Wiring real Render/Neon/GitHub Pages deploys, adding deploy secrets, promoting through `staging`, tightening CORS/rate-limiting/CSP for production. |
| **7 — Launch** | First real league data ingested, `staging` → `master` promotion, site live for the group. |
| **8 — Post-Launch Iteration** | Bug fixes, new features, and any league-rule changes (e.g. scoring tweaks) discovered once in real use. |

## Maintenance rule

Every new Issue created under the standard workflow (`docs/workflow.md`) — in either repo — must also be added to the board and assigned a Phase, as part of "before starting work." This is an ongoing responsibility for whoever does the tracked work here (including Claude Code), not a one-time setup task.
