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
 *
 * Everything lives on `SlskdClient`: construct one with an explicit base URL
 * and API key, or `SlskdClient.fromConfig()` to take them from the
 * environment. Nothing here runs at import time.
 */

import { randomUUID } from "node:crypto";

import { config } from "../../config.ts";

/** Every path below is relative to this. slskd has no other API version yet. */
const API_PREFIX = "/api/v0";

const DEFAULT_TIMEOUT_MS = 10_000;

/**
 * How long `enqueueFirstAccepted()` watches a freshly queued transfer before
 * deciding the peer took it. A refusal does not come back with the enqueue --
 * the files appear queued first and flip to "Completed, Rejected" a moment
 * later -- so this has to outlast that flip. Short enough that walking a few
 * peers stays inside one deferred interaction.
 */
const DEFAULT_VERIFY_MS = 10_000;
const VERIFY_POLL_MS = 1_000;

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

/** One peer's offer of the same content, for `enqueueFirstAccepted`. */
export interface SlskdCandidate {
  readonly username: string;
  readonly files: readonly SlskdDownloadRequest[];
}

/** Why one peer did not take the download. */
export interface SlskdRejection {
  readonly username: string;
  readonly reason: string;
}

export interface SlskdEnqueueResult {
  /** The peer that took it. */
  readonly username: string;
  readonly fileCount: number;
  /** Peers tried and passed over first, in the order they were tried. */
  readonly rejected: readonly SlskdRejection[];
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

export class SlskdClient {
  /** True when both SLSKD_URL and SLSKD_API_KEY are set. */
  static isConfigured(): boolean {
    return config.slskdUrl !== null && config.slskdApiKey !== null;
  }

  /**
   * Build a client from SLSKD_URL and SLSKD_API_KEY.
   *
   * Deliberately not a module-level `new SlskdClient(...)` like musicbrainz.ts:
   * slskd's settings are optional, and constructing at import time would make
   * an unconfigured lab fail to import the whole music feature rather than fail
   * the one command that needs slskd. Call this where slskd is actually used,
   * and keep the instance for as long as that use lasts.
   */
  static fromConfig(overrides: Partial<SlskdClientOptions> = {}): SlskdClient {
    const baseUrl = overrides.baseUrl ?? config.slskdUrl;
    const apiKey = overrides.apiKey ?? config.slskdApiKey;

    if (baseUrl === null || apiKey === null) {
      throw new SlskdError(
        "slskd is not configured. Set SLSKD_URL and SLSKD_API_KEY.\n" +
          "  dev:  apps/homelab-bot/.env, or .env at the repo root\n" +
          "  host: sops secrets/sorbet/homelab-bot.env",
      );
    }

    return new SlskdClient({ ...overrides, baseUrl, apiKey });
  }

  /**
   * slskd reports a finished search as a completion plus a reason, so the
   * state is a comma-joined pair rather than a single word.
   */
  static isSearchComplete(state: string): boolean {
    return state.startsWith("Completed");
  }

  /** True once a transfer has stopped moving, whatever the outcome. */
  static isTransferComplete(state: string): boolean {
    return state.startsWith("Completed");
  }

  /**
   * A transfer that has actually started moving bytes. A peer can still
   * refuse one that is merely queued, so this is the first point at which a
   * transfer counts as genuinely accepted.
   */
  static isTransferUnderway(transfer: SlskdTransfer): boolean {
    return transfer.state === "InProgress" || transfer.bytesTransferred > 0;
  }

  /** Stopped, and not because it finished: errored, cancelled, rejected. */
  static isTransferFailed(state: string): boolean {
    return (
      SlskdClient.isTransferComplete(state) && state !== "Completed, Succeeded"
    );
  }

  readonly #baseUrl: string;
  readonly #apiKey: string;
  readonly #timeoutMs: number;

  constructor(options: SlskdClientOptions) {
    this.#baseUrl = SlskdClient.#normalizeBaseUrl(options.baseUrl);
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
      while (
        !SlskdClient.isSearchComplete(search.state) &&
        Date.now() < deadline
      ) {
        await SlskdClient.#delay(SEARCH_POLL_MS);
        search = await this.getSearch(created.id);
      }

      return {
        search,
        responses: await this.searchResponses(created.id),
        timedOut: !SlskdClient.isSearchComplete(search.state),
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

  /**
   * Queue from the first peer that actually takes the files, trying the
   * candidates in order.
   *
   * `enqueue` returning is not acceptance: slskd forwards the request and the
   * peer decides, so a refusal surfaces afterwards as a transfer that errors
   * or that slskd never lists at all. This watches each attempt for
   * `verifyMs` and moves to the next peer when it fails, cleaning up the dead
   * entries so they do not show up later as failed downloads.
   *
   * A transfer still merely *queued* when the window runs out counts as
   * accepted: sitting in a peer's queue is the normal path, and waiting it
   * out would take far longer than any interaction lives. It cannot be
   * accepted on sight, though -- a refused transfer is queued for a moment
   * first, so an immediate answer would call every peer a success.
   *
   * Throws when every candidate refused; the message lists what each said.
   */
  async enqueueFirstAccepted(
    candidates: readonly SlskdCandidate[],
    options: { verifyMs?: number } = {},
  ): Promise<SlskdEnqueueResult> {
    const { verifyMs = DEFAULT_VERIFY_MS } = options;
    const rejected: SlskdRejection[] = [];

    for (const candidate of candidates) {
      if (candidate.files.length === 0) continue;

      try {
        await this.enqueue(candidate.username, candidate.files);
      } catch (error) {
        // A non-2xx here is slskd itself refusing -- an offline peer, most
        // often. Same outcome as a rejection, so treat it as one.
        if (!(error instanceof SlskdError)) throw error;
        rejected.push({ username: candidate.username, reason: error.message });
        continue;
      }

      const failure = await this.#verifyAccepted(candidate, verifyMs);
      if (failure === undefined) {
        return {
          username: candidate.username,
          fileCount: candidate.files.length,
          rejected,
        };
      }

      rejected.push({ username: candidate.username, reason: failure });
      await this.#discardFailed(candidate);
    }

    throw new SlskdError(
      rejected.length === 0
        ? "No peer was offered the download: every candidate had no files."
        : `No peer accepted the download. ` +
          rejected
            .map(({ username, reason }) => `${username}: ${reason}`)
            .join("; "),
    );
  }

  /**
   * Watch a just-queued transfer. Returns undefined once it looks accepted,
   * or the reason it did not.
   */
  async #verifyAccepted(
    candidate: SlskdCandidate,
    verifyMs: number,
  ): Promise<string | undefined> {
    const wanted = new Set(candidate.files.map((file) => file.filename));
    const deadline = Date.now() + verifyMs;
    let everListed = false;

    for (;;) {
      const mine = (await this.#transfersFor(candidate.username)).filter(
        (transfer) => wanted.has(transfer.filename),
      );
      everListed ||= mine.length > 0;

      const failed = mine.filter((transfer) =>
        SlskdClient.isTransferFailed(transfer.state),
      );

      // Every file refused: settled, and the next peer can be tried at once.
      if (mine.length > 0 && failed.length === mine.length) {
        const first = failed[0];
        return first?.exception ?? first?.state ?? "the peer refused it";
      }

      // Bytes are moving, or already moved. Nothing a refusal can undo, so
      // this is the one state worth accepting before the window is out.
      if (mine.some(SlskdClient.isTransferUnderway)) return undefined;

      if (Date.now() >= deadline) {
        // Still queued with no refusal in sight: a real queue, so take it.
        if (mine.length > failed.length) return undefined;
        return everListed
          ? "every file was refused"
          : "slskd never listed the transfer";
      }

      await SlskdClient.#delay(VERIFY_POLL_MS);
    }
  }

  /**
   * Drop a failed attempt's entries so the next peer's transfer is the only
   * one a status view reports. Best effort: losing the cleanup is untidy, not
   * wrong, and must not sink an enqueue that is about to be retried.
   */
  async #discardFailed(candidate: SlskdCandidate): Promise<void> {
    const wanted = new Set(candidate.files.map((file) => file.filename));

    for (const transfer of await this.#transfersFor(candidate.username)) {
      if (!wanted.has(transfer.filename)) continue;
      if (!SlskdClient.isTransferFailed(transfer.state)) continue;

      await this.cancelDownload(candidate.username, transfer.id, true).catch(
        (error: unknown) => {
          console.warn(
            `Could not remove failed slskd transfer ${transfer.id}:`,
            error,
          );
        },
      );
    }
  }

  /**
   * One peer's transfers, flattened out of slskd's directory grouping. A peer
   * with nothing queued is a 404 over there, which is an empty list here.
   */
  async #transfersFor(username: string): Promise<readonly SlskdTransfer[]> {
    try {
      const user = await this.downloadsFor(username);
      return user.directories.flatMap((directory) => directory.files);
    } catch (error) {
      if (error instanceof SlskdError && error.status === 404) return [];
      throw error;
    }
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
          SlskdClient.#hint(response.status) +
          (text === "" ? "" : ` -- ${SlskdClient.#truncate(text)}`),
        { status: response.status, body: text },
      );
    }

    return response;
  }

  /**
   * Accepts "127.0.0.1:5030", "http://127.0.0.1:5030" or a trailing slash.
   * A bare host gets http://, because the address that works from the lab host
   * is the container's, and that one has no TLS in front of it.
   */
  static #normalizeBaseUrl(value: string): string {
    const trimmed = value.trim();
    const withScheme = /^https?:\/\//i.test(trimmed)
      ? trimmed
      : `http://${trimmed}`;
    return withScheme.replace(/\/+$/, "");
  }

  static #hint(status: number): string {
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

  static #truncate(text: string, limit = 200): string {
    const oneLine = text.replace(/\s+/g, " ").trim();
    return oneLine.length > limit ? `${oneLine.slice(0, limit)}...` : oneLine;
  }

  static #delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
