import { registerAs } from '@nestjs/config';

// See docs/league-scoring-technical.md §1 — BASE_POINTS must never be hardcoded inline.
export default registerAs('scoring', () => ({
  basePoints: parseInt(process.env.SCORING_BASE_POINTS ?? '100', 10),
}));
