import type { IRelease } from "musicbrainz-api";

/** MusicBrainz queries are Lucene; a phrase value cannot carry a bare quote. */
export function escapeLucene(value: string): string {
  return value.replace(/["\\]/g, (character) => `\\${character}`);
}

export function trackCount(release: IRelease): number | undefined {
  if (release["track-count"] !== undefined) return release["track-count"];
  const total =
    release.media?.reduce((sum, medium) => sum + medium["track-count"], 0) ?? 0;
  return total > 0 ? total : undefined;
}

/** Discord rejects a field over its cap, so trim with an ellipsis. */
export function clamp(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}
