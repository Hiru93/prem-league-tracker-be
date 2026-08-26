import { Controller } from '@nestjs/common';
import { MeleeSyncService } from './melee-sync.service';

// POST /admin/leagues/:leagueId/sync, PATCH .../stages/:stageId/excluded — Phase 2.
// See docs/melee-integration-technical.md §2a/§2c.
@Controller()
export class MeleeSyncController {
  constructor(private readonly meleeSyncService: MeleeSyncService) {}
}
