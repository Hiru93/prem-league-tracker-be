import { Controller } from '@nestjs/common';
import { DecklistsService } from './decklists.service';

// Routes land in Phase 2/3 — see docs/backend-api-contract-technical.md (frontend repo).
@Controller()
export class DecklistsController {
  constructor(private readonly decklistsService: DecklistsService) {}
}
