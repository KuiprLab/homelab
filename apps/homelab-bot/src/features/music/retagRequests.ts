import { randomUUID } from "node:crypto";
import { mkdir, readdir, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { config } from "../../config.ts";

/** Requests older than this were never picked up; the unit is not running. */
const MAX_AGE_MS = 24 * 60 * 60 * 1000;

export interface RetagRequest {
  readonly albumId: number;
  readonly releaseId: string;
  readonly label: string;
  readonly requestedAt: string;
}

export class RetagError extends Error {
  constructor(message: string, options: { cause?: unknown } = {}) {
    super(message, options);
    this.name = "RetagError";
  }
}

export function isRetagConfigured(): boolean {
  return config.beetsRetagDir !== null;
}

export async function requestRetag(
  request: Omit<RetagRequest, "requestedAt">,
): Promise<void> {
  const directory = config.beetsRetagDir;
  if (directory === null) {
    throw new RetagError(
      "Retagging is not configured. Set BEETS_RETAG_DIR and deploy the " +
        "beets-retag unit.",
    );
  }

  try {
    await mkdir(directory, { recursive: true });
    await pruneStale(directory);
    await writeFile(
      join(directory, `${randomUUID()}.json`),
      JSON.stringify(
        { ...request, requestedAt: new Date().toISOString() },
        null,
        2,
      ),
    );
  } catch (cause) {
    throw new RetagError("Could not write the retag request.", { cause });
  }
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
      console.warn(`Could not prune stale retag request ${path}:`, error);
    }
  }
}
