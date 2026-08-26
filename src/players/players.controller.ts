import { Controller } from '@nestjs/common';
import { PlayersService } from './players.service';

// Routes land in Phase 2/3 — see docs/backend-api-contract-technical.md (frontend repo).
@Controller()
export class PlayersController {
  constructor(private readonly playersService: PlayersService) {}
}
