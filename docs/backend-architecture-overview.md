# Backend Architecture — Overview

## What this is

The Prem League Tracker backend is a single API service, built with [NestJS](https://nestjs.com) (a TypeScript framework for Node.js), that serves league data — stages, players, standings, decklists — to the frontend. This doc describes how the codebase is organized so the project stays easy to navigate and extend as a solo/small-team effort.

## Why NestJS

NestJS gives structure "for free": it enforces a modular architecture (features live in self-contained modules), has first-class TypeScript support, and has mature, well-documented building blocks for the things this project needs — request validation, guards for auth/rate-limiting, scheduled jobs, and a clean dependency-injection story for wiring services together and testing them in isolation.

## How the code is organized, in plain terms

Each feature area of the league (stages, players, decklists, scoring, the melee.gg import, the Scryfall lookup) lives in its own self-contained folder/module. Since the second corner-case review (2026-08-26), the platform also runs multiple leagues at once, each its own tenant — so there are three more modules alongside the league-feature ones: one owning leagues themselves (creating a league, listing them for the public league picker), one owning admin login (JWT access tokens, rotating refresh-token cookies, and the guards every admin route depends on), and one owning admin-account creation (kept separate from login since only the super-admin can create other admins). See `backend-architecture-technical.md` for the exact module list. A module typically has three layers:

- **Controller** — handles incoming HTTP requests, does no business logic itself.
- **Service** — contains the actual logic (e.g. "compute standings for this league").
- **Repository/Prisma access** — talks to the database.

This separation means, for example, that the scoring logic can be unit-tested without spinning up a real HTTP server or a real database, and that changing how data is stored (which table, which columns) doesn't force changes to the business logic that uses it.

## Why Prisma

We use [Prisma](https://www.prisma.io) as the database toolkit (over the alternative, TypeORM) because it has stronger TypeScript type-safety (generated types match the schema exactly) and a simpler, more reliable migrations workflow — both of which matter more than raw flexibility for a project maintained by one or two people in their spare time.

## Related docs

- `data-model-overview.md` — the actual database schema this architecture sits on top of.
- `security-overview.md` — how requests are validated and the API is protected.
- `hosting-deployment-be-overview.md` — where and how this service runs in production.
