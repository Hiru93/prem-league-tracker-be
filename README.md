# prem-league-tracker-be

Backend API for Prem League Tracker — a multi-league Magic: The Gathering tournament tracker, ingesting data from melee.gg.

Built with [NestJS](https://nestjs.com) + [Prisma](https://www.prisma.io) + Postgres. See `docs/` for the full architecture, data model, and API contract; `docs/workflow.md` for how contributions are tracked (every change traces to a GitHub Issue).

## Development

```bash
npm install
npm run start:dev
```

Requires a `DATABASE_URL` (see `.env.example` and `docs/hosting-deployment-be-technical.md`).

## Scripts

- `npm run start:dev` — run locally with hot reload
- `npm run build` — compile to `dist/`
- `npm run lint` — eslint
- `npm test` — unit tests
- `npm run test:e2e` — e2e tests (requires a running test database)
