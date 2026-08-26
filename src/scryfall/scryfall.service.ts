import { Injectable } from '@nestjs/common';

// Card resolution + Redis caching lands in Phase 2 — see docs/scryfall-integration-technical.md.
// No controller for MVP (resolution is invoked internally during decklist ingestion).
@Injectable()
export class ScryfallService {}
