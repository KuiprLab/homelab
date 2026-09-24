/**
 * Import hints: what the bot knows at click time and beets has to guess at
 * import time.
 *
 * The pipeline is one-way -- slskd finishes a directory, a systemd path unit
 * runs `beet import` on it (services/music/beets.nix) -- and by then the
 * MusicBrainz release the user actually picked is gone. beets re-derives it
 * from tags and filenames, which is exactly what fails on a Soulseek rip: a
 * reissue folder matched against the original release scores far enough off
 * that `quiet_fallback: skip` parks the whole album in slskd-review.
 *
 * So the bot leaves the answer on disk. One small JSON file per enqueue,
 * naming the remote directory the files came from and the release id the user
 * chose; the import script looks for a hint matching the finished directory
 * and passes `--search-id` when it finds one.
 *
 * Deliberately a dropped file rather than a call: the two sides are different
 * units, running as different users, minutes to hours apart, and the hint has
 * to survive a bot restart in between.
 */

import { randomUUID } from "node:crypto";
import {
  mkdir,
  readdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";

import { config } from "../../config.ts";

/**
 * How long a hint stays useful. A transfer can sit in a peer's queue for a
 * long time, so this is generous; past it the download is never coming.
 */
const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

export interface ImportHint {
  /**
   * The peer's own directory name, which is what slskd names the local
   * download directory after -- the join key on the beets side.
   */
  readonly directory: string;
  /** MusicBrainz release id, the whole point of the hint. */
  readonly releaseId: string;
  /** For a human reading the file or the import log. */
  readonly title: string;
  readonly artist: string;
  readonly queuedAt: string;
}

/**
 * Record what a queued download is meant to be. Best effort by design: a
 * missing hint costs an unattended import, not the download, so a failure
 * here is warned about and swallowed.
 */
export async function rememberImportHint(
  hint: Omit<ImportHint, "queuedAt">,
): Promise<void> {
  const directory = config.beetsHintsDir;
  if (directory === null) return;

  try {
    await mkdir(directory, { recursive: true });
    await pruneStale(directory);

    // A random name, not one derived from the directory: the two sides would
    // then have to agree on how to make a path-safe key out of a string full
    // of braces, brackets and spaces. The script matches on the field.
    await writeFile(
      join(directory, `${randomUUID()}.json`),
      JSON.stringify({ ...hint, queuedAt: new Date().toISOString() }, null, 2),
    );
  } catch (error) {
    console.warn("Could not write a beets import hint:", error);
  }
}

/**
 * The directory a peer is sharing these files from -- its last path segment.
 * Peers send Windows-style paths, so the separator is usually a backslash.
 */
export function remoteDirectoryOf(filename: string): string | undefined {
  const segments = filename.split(/[\\/]/).filter((part) => part !== "");
  // The last segment is the file; the one before it is its directory.
  return segments.length >= 2 ? segments[segments.length - 2] : undefined;
}

/**
 * Drop hints too old to belong to anything still downloading. Nothing else
 * collects them: the import script runs as another user and cannot unlink
 * from this directory.
 */
async function pruneStale(directory: string): Promise<void> {
  const cutoff = Date.now() - MAX_AGE_MS;

  for (const entry of await readdir(directory)) {
    if (!entry.endsWith(".json")) continue;
    const path = join(directory, entry);

    try {
      if ((await stat(path)).mtimeMs >= cutoff) continue;
      await rm(path, { force: true });
    } catch (error) {
      console.warn(`Could not prune stale hint ${path}:`, error);
    }
  }
}

/** Read the hints on disk. For tests and for a future /music hints view. */
export async function readImportHints(): Promise<readonly ImportHint[]> {
  const directory = config.beetsHintsDir;
  if (directory === null) return [];

  const hints: ImportHint[] = [];
  for (const entry of await readdir(directory)) {
    if (!entry.endsWith(".json")) continue;
    hints.push(
      JSON.parse(await readFile(join(directory, entry), "utf8")) as ImportHint,
    );
  }
  return hints;
}
