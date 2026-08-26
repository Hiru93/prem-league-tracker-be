import { Controller } from '@nestjs/common';
import { StagesService } from './stages.service';

// Routes land in Phase 2/3 — see docs/backend-api-contract-technical.md (frontend repo).
@Controller()
export class StagesController {
  constructor(private readonly stagesService: StagesService) {}
}
