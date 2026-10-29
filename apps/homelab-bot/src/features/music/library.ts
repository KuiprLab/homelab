import { DatabaseSync } from "node:sqlite";

import { config } from "../../config.ts";

export interface IncompleteAlbum {
  readonly albumartist: string;
  readonly album: string;
  readonly releaseId: string | undefined;
  readonly have: number;
  readonly expect: number;
  readonly discs: number;
  readonly discsPresent: number;
}

// tracktotal repeats the whole-release total on every item: MAX, not a sum over discs.
const MISSING_QUERY = `
  SELECT
    a.albumartist AS albumartist,
    a.album AS album,
    a.mb_albumid AS releaseId,
    COUNT(i.id) AS have,
    MAX(i.tracktotal) AS expect,
    MAX(i.disctotal) AS discs,
    COUNT(DISTINCT i.disc) AS discsPresent
  FROM albums a
  JOIN items i ON i.album_id = a.id
  GROUP BY a.id
  HAVING expect > 0 AND have < expect
  ORDER BY (expect - have) DESC, a.albumartist, a.album
  LIMIT ?
`;

function releaseIdOf(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  return /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : undefined;
}

export interface LibraryAlbum {
  readonly id: number;
  readonly albumartist: string;
  readonly album: string;
  readonly tracks: number;
  readonly currentId: string;
  readonly source: string;
}

const SEARCH_QUERY = `
  SELECT a.id AS id, a.albumartist AS albumartist, a.album AS album,
    a.mb_albumid AS currentId, COUNT(i.id) AS tracks,
    COALESCE((
      SELECT f.value FROM album_attributes f
      WHERE f.entity_id = a.id AND f.key = 'data_source'
    ), '') AS source
  FROM albums a
  JOIN items i ON i.album_id = a.id
  WHERE a.album LIKE '%' || ? || '%'
     OR a.albumartist || ' ' || a.album LIKE '%' || ? || '%'
  GROUP BY a.id
  ORDER BY a.albumartist, a.album
  LIMIT ?
`;

export function findAlbums(
  text: string,
  limit: number,
): readonly LibraryAlbum[] {
  return query((database) =>
    database
      .prepare(SEARCH_QUERY)
      .all(text, text, limit)
      .map((row) => {
        const record = row as Record<string, unknown>;
        return {
          id: Number(record["id"] ?? 0),
          albumartist: String(record["albumartist"] ?? "Unknown"),
          album: String(record["album"] ?? "Unknown"),
          tracks: Number(record["tracks"] ?? 0),
          currentId: String(record["currentId"] ?? ""),
          source: String(record["source"] ?? ""),
        };
      }),
  );
}

export class LibraryError extends Error {
  constructor(message: string, options: { cause?: unknown } = {}) {
    super(message, options);
    this.name = "LibraryError";
  }
}

export function isLibraryConfigured(): boolean {
  return config.beetsLibrary !== null;
}

export function incompleteAlbums(limit: number): readonly IncompleteAlbum[] {
  return query((database) =>
    database
      .prepare(MISSING_QUERY)
      .all(limit)
      .map((row) => {
        const record = row as Record<string, unknown>;
        return {
          albumartist: String(record["albumartist"] ?? "Unknown"),
          album: String(record["album"] ?? "Unknown"),
          releaseId: releaseIdOf(record["releaseId"]),
          have: Number(record["have"] ?? 0),
          expect: Number(record["expect"] ?? 0),
          discs: Number(record["discs"] ?? 1),
          discsPresent: Number(record["discsPresent"] ?? 1),
        };
      }),
  );
}

function query<T>(read: (database: DatabaseSync) => T): T {
  const path = config.beetsLibrary;
  if (path === null) {
    throw new LibraryError(
      "The beets library is not configured. Set BEETS_LIBRARY to " +
        "/home/daniel/.beets/library.db.",
    );
  }

  let database: DatabaseSync;
  try {
    database = new DatabaseSync(path, { readOnly: true });
  } catch (cause) {
    console.warn(`Could not open the beets library at ${path}:`, cause);
    throw new LibraryError(`Could not open the beets library at ${path}.`, {
      cause,
    });
  }

  try {
    return read(database);
  } catch (cause) {
    if (cause instanceof LibraryError) throw cause;
    throw new LibraryError("Could not read the beets library.", { cause });
  } finally {
    database.close();
  }
}
