/**
 * The beets library, read-only.
 *
 * Opened directly rather than by shelling out to `beet`: the importer runs as
 * another user in another unit, and the bot has no business holding a write
 * handle on that database. node:sqlite's readOnly mode makes that structural
 * rather than a promise.
 *
 * beets journals in "delete" mode, not WAL, so a single-file read needs no
 * sidecar files and cannot be blocked by an import in progress.
 */

import { DatabaseSync } from "node:sqlite";

import { config } from "../../config.ts";

/** An album the library has, but not all of. */
export interface IncompleteAlbum {
  readonly albumartist: string;
  readonly album: string;
  /** MusicBrainz release id, when the album was tagged with one. */
  readonly releaseId: string | undefined;
  readonly have: number;
  readonly expect: number;
  /** Discs the release has, and how many of them the library holds anything from. */
  readonly discs: number;
  readonly discsPresent: number;
}

/**
 * What "missing" means here.
 *
 * beets stores no album-level track total. tracktotal lives on each item, and
 * what it counts depends on per_disc_numbering: with it off -- the default,
 * and what this library uses -- tracks are numbered straight through a
 * release and tracktotal is the total for the WHOLE release, repeated on
 * every item, disc two included. So the album total is MAX(tracktotal), not a
 * sum over discs: summing reported Minenwerfer's seven tracks across two
 * discs as 7 of 14.
 *
 * disctotal and the number of discs actually present come along so the caller
 * can tell "four tracks never downloaded" from "this is the first disc of a
 * two-disc reissue" -- the same arithmetic, very different problems.
 */
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

/**
 * mb_albumid is not always a MusicBrainz id. The spotify plugin writes its
 * own ids into the same column -- "5r4qa5AIQUVypFRXQzjaiu" sits on Chaos A.D.
 * in this library -- and handing one of those to a MusicBrainz lookup just
 * fails. Only a UUID is worth offering a button for; an untagged album stores
 * an empty string here rather than null.
 */
function releaseIdOf(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  return /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : undefined;
}

export class LibraryError extends Error {
  constructor(message: string, options: { cause?: unknown } = {}) {
    super(message, options);
    this.name = "LibraryError";
  }
}

/** True when BEETS_LIBRARY is set. */
export function isLibraryConfigured(): boolean {
  return config.beetsLibrary !== null;
}

/**
 * Albums with fewer tracks than the release says they should have.
 *
 * Opened and closed per call: the file is rewritten by imports happening
 * outside this process, and a handle held open would eventually be looking at
 * a database that no longer exists.
 */
export function incompleteAlbums(limit: number): readonly IncompleteAlbum[] {
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
    // Logged as well as wrapped: the reply says the library could not be
    // opened, and only the cause says whether that was permissions, a missing
    // path, or a file that is not a database.
    console.warn(`Could not open the beets library at ${path}:`, cause);
    throw new LibraryError(`Could not open the beets library at ${path}.`, {
      cause,
    });
  }

  try {
    const rows = database.prepare(MISSING_QUERY).all(limit);

    return rows.map((row) => {
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
    });
  } catch (cause) {
    throw new LibraryError("Could not read the beets library.", { cause });
  } finally {
    database.close();
  }
}
