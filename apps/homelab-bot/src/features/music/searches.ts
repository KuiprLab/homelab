import { randomBytes } from "node:crypto";
import type { IReleaseMatch } from "musicbrainz-api";

/**
 * The results of one /music find, kept so the picker can offer the runners-up
 * without searching MusicBrainz again.
 *
 * Buttons would rather carry their whole subject in the customId, which needs
 * no state at all -- but that caps at 100 characters and four more MusicBrainz
 * ids do not fit, so the picker carries a key into this table instead. Two
 * consequences follow, and both are deliberate: showing the modal needs no
 * network round trip (Discord does not allow deferring one), and a click only
 * works while the entry lives. Past the TTL, or after a restart, the handler
 * says so and asks for a fresh search.
 */
export interface Search {
  readonly query: string;
  readonly releases: readonly IReleaseMatch[];
  readonly storedAt: number;
}

/** Long enough to pick from a search, short enough to stay small. */
const TTL_MS = 30 * 60 * 1000;

/** A ceiling so a busy channel cannot grow this without bound. */
const MAX_ENTRIES = 500;

const searches = new Map<string, Search>();

/** Store a result set and return the key the picker travels with. */
export function rememberSearch(
  query: string,
  releases: readonly IReleaseMatch[],
): string {
  // base64url so the key cannot contain the ":" a customId splits on.
  const key = randomBytes(6).toString("base64url");
  searches.set(key, { query, releases, storedAt: Date.now() });

  // A Map iterates in insertion order, so the front is the oldest.
  while (searches.size > MAX_ENTRIES) {
    const oldest = searches.keys().next();
    if (oldest.done === true) break;
    searches.delete(oldest.value);
  }

  return key;
}

/** The stored results, or undefined once they have expired. */
export function recallSearch(key: string): Search | undefined {
  const search = searches.get(key);
  if (search === undefined) return undefined;
  if (Date.now() - search.storedAt > TTL_MS) {
    searches.delete(key);
    return undefined;
  }
  return search;
}
