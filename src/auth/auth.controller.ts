import { Controller } from '@nestjs/common';
import { AuthService } from './auth.service';

// POST /admin/auth/login|refresh|logout|logout-all — Phase 3.
// See docs/security-technical.md §Login flow / §Refresh flow / §Logout.
@Controller()
export class AuthController {
  constructor(private readonly authService: AuthService) {}
}
