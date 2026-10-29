import { randomBytes } from "node:crypto";
import type { IReleaseMatch } from "musicbrainz-api";

export interface Search {
  readonly query: string;
  readonly releases: readonly IReleaseMatch[];
  readonly storedAt: number;
}

const TTL_MS = 30 * 60 * 1000;

const MAX_ENTRIES = 500;

const searches = new Map<string, Search>();

export function rememberSearch(
  query: string,
  releases: readonly IReleaseMatch[],
): string {
  const key = randomBytes(6).toString("base64url");
  searches.set(key, { query, releases, storedAt: Date.now() });

  while (searches.size > MAX_ENTRIES) {
    const oldest = searches.keys().next();
    if (oldest.done === true) break;
    searches.delete(oldest.value);
  }

  return key;
}

export function recallSearch(key: string): Search | undefined {
  const search = searches.get(key);
  if (search === undefined) return undefined;
  if (Date.now() - search.storedAt > TTL_MS) {
    searches.delete(key);
    return undefined;
  }
  return search;
}
