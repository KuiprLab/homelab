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

const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

export interface ImportHint {
  /** Peer directory name: slskd names the download dir after it; beets joins on it. */
  readonly directory: string;
  readonly releaseId: string;
  readonly title: string;
  readonly artist: string;
  readonly complete?: boolean;
  readonly queuedAt: string;
}

export async function rememberImportHint(
  hint: Omit<ImportHint, "queuedAt">,
): Promise<void> {
  const directory = config.beetsHintsDir;
  if (directory === null) return;

  try {
    await mkdir(directory, { recursive: true });
    await pruneStale(directory);

    await writeFile(
      join(directory, `${randomUUID()}.json`),
      JSON.stringify({ ...hint, queuedAt: new Date().toISOString() }, null, 2),
    );
  } catch (error) {
    console.warn("Could not write a beets import hint:", error);
  }
}

export function remoteDirectoryOf(filename: string): string | undefined {
  const segments = filename.split(/[\\/]/).filter((part) => part !== "");
  return segments.length >= 2 ? segments[segments.length - 2] : undefined;
}

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
