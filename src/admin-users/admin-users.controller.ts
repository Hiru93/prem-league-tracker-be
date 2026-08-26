import { Controller } from '@nestjs/common';
import { AdminUsersService } from './admin-users.service';

// Routes land in Phase 2/3 — see docs/backend-api-contract-technical.md (frontend repo).
@Controller()
export class AdminUsersController {
  constructor(private readonly adminUsersService: AdminUsersService) {}
}
