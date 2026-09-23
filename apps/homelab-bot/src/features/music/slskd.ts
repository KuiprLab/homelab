/**
 * slskd's HTTP API -- enough of it for the music feature to search Soulseek
 * and queue downloads.
 *
 * Auth is an API key in the `X-API-Key` header, declared under
 * `web.authentication.api_keys` in secrets/sorbet/slskd.yml. Point SLSKD_URL
 * at the container's own address (http://127.0.0.1:5030) and not at
 * slskd.int.kuipr.de: the public vhost sits behind authelia, which answers an
 * API-key request with a login page instead of JSON.
 *
 * Searching is asynchronous over there. Creating a search returns immediately
 * with nothing in it, and responses trickle in from the network over the next
 * several seconds. `search()` hides that behind a single await by polling --
 * which takes far longer than Discord's three-second interaction window, so a
 * command calling it has to `deferReply()` first.
 */

import { randomUUID } from "node:crypto";

import { config } from "../../config.ts";

/** Every path below is relative to this. slskd has no other API version yet. */
const API_PREFIX = "/api/v0";

const DEFAULT_TIMEOUT_MS = 10_000;

/** How long `search()` waits for slskd to stop collecting responses. */
const DEFAULT_SEARCH_WAIT_MS = 20_000;
const SEARCH_POLL_MS = 750;

/**
 * Anything that went wrong talking to slskd: a refused connection, a timeout,
 * a non-2xx answer. One type so a caller needs one catch.
 */
export class SlskdError extends Error {
  /** The HTTP status, or 0 when the request never got an answer at all. */
  readonly status: number;
  /** Response body, when there was one. slskd puts its detail here. */
  readonly body: string;

  constructor(
    message: string,
    options: { status?: number; body?: string; cause?: unknown } = {},
  ) {
    super(message, { cause: options.cause });
    this.name = "SlskdError";
    this.status = options.status ?? 0;
    this.body = options.body ?? "";
  }
}

/**
 * One file on one peer. slskd returns more fields than this; these are the
 * ones that survive a peer that fills in almost nothing, which is common --
 * only `filename` and `size` are reliably present.
 */
export interface SlskdFile {
  readonly filename: string;
  readonly size: number;
  readonly extension?: string;
  readonly bitRate?: number;
  readonly bitDepth?: number;
  readonly sampleRate?: number;
  /** Duration in seconds. */
  readonly length?: number;
  readonly isVariableBitRate?: boolean;
}

/** What one peer offered for a search. */
export interface SlskdSearchResponse {
  readonly username: string;
  readonly hasFreeUploadSlot: boolean;
  /** Files ahead of yours if you queue with this peer now. */
  readonly queueLength: number;
  /** Bytes per second, as the peer reports it. */
  readonly uploadSpeed: number;
  readonly fileCount: number;
  readonly lockedFileCount: number;
  readonly files: readonly SlskdFile[];
  /** Files the peer will only share with users it has privileges for. */
  readonly lockedFiles: readonly SlskdFile[];
}

export interface SlskdSearch {
  readonly id: string;
  readonly searchText: string;
  readonly token: number;
  /**
   * "Requested", "InProgress", or a completion and its reason:
   * "Completed, TimedOut", "Completed, ResponseLimitReached", ... Use
   * `isSearchComplete` rather than comparing this to a literal.
   */
  readonly state: string;
  readonly fileCount: number;
  readonly lockedFileCount: number;
  readonly responseCount: number;
  readonly startedAt?: string;
  readonly endedAt?: string;
  /** Only populated when the search was fetched with responses. */
  readonly responses?: readonly SlskdSearchResponse[];
}

export interface SlskdSearchOptions {
  /** slskd wants a GUID; one is generated when this is left out. */
  readonly id?: string;
  /** Stop after this many files across all responses. */
  readonly fileLimit?: number;
  /** Stop after this many responding peers. */
  readonly responseLimit?: number;
  /** Ignore peers offering fewer files than this. */
  readonly minimumResponseFileCount?: number;
  /** Ignore peers slower than this, in bytes per second. */
  readonly minimumPeerUploadSpeed?: number;
  /** Ignore peers with a longer queue than this. */
  readonly maximumPeerQueueLength?: number;
  /** How long slskd itself keeps the search open, in milliseconds. */
  readonly searchTimeout?: number;
}

export interface SlskdSearchResult {
  readonly search: SlskdSearch;
  readonly responses: readonly SlskdSearchResponse[];
  /**
   * True when the wait gave up before slskd finished. The responses collected
   * so far are still returned -- a partial answer beats no answer, since a
   * search that found plenty in two seconds keeps running to its timeout
   * regardless.
   */
  readonly timedOut: boolean;
}

/** One queued or running transfer. */
export interface SlskdTransfer {
  readonly id: string;
  readonly username: string;
  readonly direction: "Download" | "Upload";
  readonly filename: string;
  readonly size: number;
  /**
   * "Queued, Remotely", "InProgress", "Completed, Succeeded",
   * "Completed, Errored", "Completed, Cancelled", ...
   */
  readonly state: string;
  readonly bytesTransferred: number;
  readonly bytesRemaining: number;
  readonly percentComplete: number;
  /** Bytes per second. */
  readonly averageSpeed: number;
  readonly enqueuedAt?: string;
  readonly startedAt?: string;
  readonly endedAt?: string;
  /** Present on a failed transfer. */
  readonly exception?: string;
}

/** slskd groups a user's transfers by the remote directory they came from. */
export interface SlskdTransferDirectory {
  readonly directory: string;
  readonly fileCount: number;
  readonly files: readonly SlskdTransfer[];
}

export interface SlskdUserTransfers {
  readonly username: string;
  readonly directories: readonly SlskdTransferDirectory[];
}

/**
 * A file to download. The filename has to be the peer's own, verbatim from a
 * search response -- backslashes and all -- and the size has to match, or the
 * peer rejects the request.
 */
export interface SlskdDownloadRequest {
  readonly filename: string;
  readonly size: number;
}

export interface SlskdApplicationState {
  readonly version: string;
  readonly server: {
    readonly address: string;
    /** "Connected, LoggedIn" when slskd is actually usable. */
    readonly state: string;
    readonly username?: string;
  };
}

export interface SlskdClientOptions {
  /** Origin, with or without a scheme: "127.0.0.1:5030" is accepted. */
  readonly baseUrl: string;
  readonly apiKey: string;
  /** Per-request ceiling. Search polling gets its own, longer budget. */
  readonly timeoutMs?: number;
}

/**
 * slskd reports a finished search as a completion plus a reason, so the state
 * is a comma-joined pair rather than a single word.
 */
export function isSearchComplete(state: string): boolean {
  return state.startsWith("Completed");
}

export class SlskdClient {
  readonly #baseUrl: string;
  readonly #apiKey: string;
  readonly #timeoutMs: number;

  constructor(options: SlskdClientOptions) {
    this.#baseUrl = normalizeBaseUrl(options.baseUrl);
    this.#apiKey = options.apiKey;
    this.#timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  /** Where this client points, for log lines and error messages. */
  get baseUrl(): string {
    return this.#baseUrl;
  }

  /** slskd's view of itself: its version, and whether it is logged in. */
  applicationState(): Promise<SlskdApplicationState> {
    return this.#json("GET", "/application");
  }

  /** Create a search and return immediately, before any peer has answered. */
  startSearch(
    searchText: string,
    options: SlskdSearchOptions = {},
  ): Promise<SlskdSearch> {
    const { id = randomUUID(), ...rest } = options;
    return this.#json("POST", "/searches", { id, searchText, ...rest });
  }

  getSearch(id: string): Promise<SlskdSearch> {
    return this.#json("GET", `/searches/${encodeURIComponent(id)}`);
  }

  searchResponses(id: string): Promise<readonly SlskdSearchResponse[]> {
    return this.#json("GET", `/searches/${encodeURIComponent(id)}/responses`);
  }

  /** Cancels the search if it is still running, and drops it from slskd. */
  async deleteSearch(id: string): Promise<void> {
    await this.#send("DELETE", `/searches/${encodeURIComponent(id)}`);
  }

  /**
   * Search, wait for it to settle, and hand back what came in. Takes seconds,
   * not milliseconds -- defer the interaction before calling this.
   *
   * The search is deleted afterwards unless `keep` is set: slskd holds every
   * search it has ever run in memory until its retention policy expires them,
   * and the bot has no use for one it has already reported.
   */
  async search(
    searchText: string,
    options: SlskdSearchOptions & { waitMs?: number; keep?: boolean } = {},
  ): Promise<SlskdSearchResult> {
    const { waitMs = DEFAULT_SEARCH_WAIT_MS, keep = false, ...rest } = options;

    const created = await this.startSearch(searchText, rest);
    const deadline = Date.now() + waitMs;
    let search = created;

    try {
      while (!isSearchComplete(search.state) && Date.now() < deadline) {
        await delay(SEARCH_POLL_MS);
        search = await this.getSearch(created.id);
      }

      return {
        search,
        responses: await this.searchResponses(created.id),
        timedOut: !isSearchComplete(search.state),
      };
    } finally {
      if (!keep) {
        // Never let cleanup mask the result -- or the real error, when the
        // loop above is the thing that threw.
        await this.deleteSearch(created.id).catch((error: unknown) => {
          console.warn(`Could not delete slskd search ${created.id}:`, error);
        });
      }
    }
  }

  /**
   * Queue files for download from one peer. Returns as soon as slskd accepts
   * them; the transfer itself sits in the peer's queue for anywhere between
   * seconds and never. Poll `downloadsFor` to follow it.
   */
  async enqueue(
    username: string,
    files: readonly SlskdDownloadRequest[],
  ): Promise<void> {
    if (files.length === 0) return;
    await this.#send(
      "POST",
      `/transfers/downloads/${encodeURIComponent(username)}`,
      files,
    );
  }

  /** Every download slskd knows about, grouped by peer. */
  downloads(): Promise<readonly SlskdUserTransfers[]> {
    return this.#json("GET", "/transfers/downloads");
  }

  downloadsFor(username: string): Promise<SlskdUserTransfers> {
    return this.#json(
      "GET",
      `/transfers/downloads/${encodeURIComponent(username)}`,
    );
  }

  /**
   * Cancel a download. `remove` also drops it from the transfer list, which
   * is what you want for a finished or failed one; cancelling a running
   * transfer without it leaves the entry visible in the state it stopped in.
   */
  async cancelDownload(
    username: string,
    id: string,
    remove = false,
  ): Promise<void> {
    const path =
      `/transfers/downloads/${encodeURIComponent(username)}/` +
      `${encodeURIComponent(id)}?remove=${String(remove)}`;
    await this.#send("DELETE", path);
  }

  async #json<T>(method: string, path: string, body?: unknown): Promise<T> {
    const response = await this.#send(method, path, body);

    // An HTML answer here means the request never reached slskd: authelia
    // returns its login page with a 200, so the status alone does not catch
    // it. Worth naming, because it is the one misconfiguration that looks
    // like slskd itself misbehaving.
    const contentType = response.headers.get("content-type") ?? "";
    if (!contentType.includes("json")) {
      throw new SlskdError(
        `${method} ${path} answered with ${contentType || "no content type"} ` +
          `instead of JSON. If SLSKD_URL points at slskd.int.kuipr.de, that ` +
          `vhost is behind authelia -- use the container's address instead.`,
        { status: response.status },
      );
    }

    return (await response.json()) as T;
  }

  async #send(method: string, path: string, body?: unknown): Promise<Response> {
    const url = `${this.#baseUrl}${API_PREFIX}${path}`;

    let response: Response;
    try {
      response = await fetch(url, {
        method,
        headers: {
          "X-API-Key": this.#apiKey,
          Accept: "application/json",
          ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(this.#timeoutMs),
      });
    } catch (cause) {
      // fetch only rejects when there was no HTTP answer at all: DNS, a
      // refused connection, the timeout above.
      throw new SlskdError(
        `${method} ${path} could not reach slskd at ${this.#baseUrl}.`,
        { cause },
      );
    }

    if (!response.ok) {
      // Read the body before throwing; it is where slskd explains itself, and
      // it cannot be read once the response is discarded.
      const text = await response.text().catch(() => "");
      throw new SlskdError(
        `${method} ${path} failed: ${response.status} ${response.statusText}` +
          hint(response.status) +
          (text === "" ? "" : ` -- ${truncate(text)}`),
        { status: response.status, body: text },
      );
    }

    return response;
  }
}

let client: SlskdClient | undefined;

/** True when both SLSKD_URL and SLSKD_API_KEY are set. */
export function isSlskdConfigured(): boolean {
  return config.slskdUrl !== null && config.slskdApiKey !== null;
}

/**
 * The shared client, built on first use.
 *
 * Deliberately not a module-level `new SlskdClient(...)` like musicbrainz.ts:
 * slskd's settings are optional, and constructing at import time would make
 * an unconfigured lab fail to import the whole music feature rather than fail
 * the one command that needs slskd.
 */
export function slskd(): SlskdClient {
  if (client !== undefined) return client;

  const { slskdUrl, slskdApiKey } = config;
  if (slskdUrl === null || slskdApiKey === null) {
    throw new SlskdError(
      "slskd is not configured. Set SLSKD_URL and SLSKD_API_KEY.\n" +
        "  dev:  apps/homelab-bot/.env, or .env at the repo root\n" +
        "  host: sops secrets/sorbet/homelab-bot.env",
    );
  }

  client = new SlskdClient({ baseUrl: slskdUrl, apiKey: slskdApiKey });
  return client;
}

/**
 * Accepts "127.0.0.1:5030", "http://127.0.0.1:5030" or a trailing slash.
 * A bare host gets http://, because the address that works from the lab host
 * is the container's, and that one has no TLS in front of it.
 */
function normalizeBaseUrl(value: string): string {
  const trimmed = value.trim();
  const withScheme = /^https?:\/\//i.test(trimmed)
    ? trimmed
    : `http://${trimmed}`;
  return withScheme.replace(/\/+$/, "");
}

function hint(status: number): string {
  switch (status) {
    case 401:
    case 403:
      return " (the API key was rejected -- check SLSKD_API_KEY against web.authentication.api_keys in slskd.yml)";
    case 404:
      return " (no such route -- check SLSKD_URL points at slskd's root, not a path under it)";
    default:
      return "";
  }
}

function truncate(text: string, limit = 200): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length > limit ? `${oneLine.slice(0, limit)}...` : oneLine;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
