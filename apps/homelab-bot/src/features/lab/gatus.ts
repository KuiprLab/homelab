/**
 * gatus's read API -- just enough of it to answer "is anything broken".
 *
 * Point GATUS_URL at the container (http://127.0.0.1:8888) rather than
 * gatus.int.kuipr.de: the vhost is behind authelia, which answers an
 * unauthenticated request with a login page instead of JSON.
 */

import { config } from "../../config.ts";

const ENDPOINTS_PATH = "/api/v1/endpoints/statuses";

const TIMEOUT_MS = 5_000;

/** One probe run. gatus keeps a window of these per endpoint. */
interface GatusResult {
  readonly success: boolean;
  /** Nanoseconds, the way Go's time.Duration marshals. */
  readonly duration: number;
  readonly timestamp: string;
}

interface GatusEndpoint {
  readonly name: string;
  readonly group?: string;
  readonly key: string;
  readonly results?: readonly GatusResult[];
}

/** An endpoint reduced to its latest run. */
export interface Check {
  readonly name: string;
  readonly group: string;
  readonly up: boolean;
  /** Milliseconds, converted from gatus's nanoseconds. */
  readonly responseMs: number;
  readonly at: Date;
}

export class GatusError extends Error {
  constructor(message: string, options: { cause?: unknown } = {}) {
    super(message, options);
    this.name = "GatusError";
  }
}

/**
 * Every endpoint gatus watches, reduced to its most recent result.
 *
 * An endpoint with no results at all is dropped rather than reported as down:
 * gatus lists a check it has not run yet, and calling that an outage would be
 * a lie on every restart.
 */
export async function checks(): Promise<readonly Check[]> {
  const base = config.gatusUrl;
  if (base === null) {
    throw new GatusError(
      "gatus is not configured. Set GATUS_URL to the container's address, " +
        "e.g. http://127.0.0.1:8888.",
    );
  }

  const url = `${base.replace(/\/+$/, "")}${ENDPOINTS_PATH}`;

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (cause) {
    throw new GatusError(`Could not reach gatus at ${base}.`, { cause });
  }

  if (!response.ok) {
    throw new GatusError(
      `gatus answered ${response.status} ${response.statusText}.`,
    );
  }

  const endpoints = (await response.json()) as readonly GatusEndpoint[];

  return endpoints.flatMap((endpoint) => {
    // gatus returns its window oldest first, so the newest run is the last.
    const latest = endpoint.results?.at(-1);
    if (latest === undefined) return [];

    return [
      {
        name: endpoint.name,
        group: endpoint.group ?? "ungrouped",
        up: latest.success,
        responseMs: Math.round(latest.duration / 1_000_000),
        at: new Date(latest.timestamp),
      },
    ];
  });
}
