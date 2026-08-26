import { Controller } from '@nestjs/common';
import { LeaguesService } from './leagues.service';

// Routes (GET /leagues, POST /admin/leagues, ...) land in Phase 2/3 —
// see docs/backend-api-contract-technical.md (frontend repo) for the target shape.
@Controller()
export class LeaguesController {
  constructor(private readonly leaguesService: LeaguesService) {}
}
