/** GATUS_URL must point at the container: the public vhost returns authelia's login page. */

import { config } from "../../config.ts";

const ENDPOINTS_PATH = "/api/v1/endpoints/statuses";

const TIMEOUT_MS = 5_000;

interface GatusResult {
  readonly success: boolean;
  readonly duration: number;
  readonly timestamp: string;
}

interface GatusEndpoint {
  readonly name: string;
  readonly group?: string;
  readonly key: string;
  readonly results?: readonly GatusResult[];
}

export interface Check {
  readonly name: string;
  readonly group: string;
  readonly up: boolean;
  readonly responseMs: number;
  readonly at: Date;
}

export class GatusError extends Error {
  constructor(message: string, options: { cause?: unknown } = {}) {
    super(message, options);
    this.name = "GatusError";
  }
}

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
