/** SLSKD_URL must point at the container: the public vhost returns authelia's login page. */

import { randomUUID } from "node:crypto";

import { config } from "../../config.ts";

const API_PREFIX = "/api/v0";

const DEFAULT_TIMEOUT_MS = 10_000;

const DEFAULT_VERIFY_MS = 10_000;
const VERIFY_POLL_MS = 1_000;

const DEFAULT_SEARCH_WAIT_MS = 20_000;
const SEARCH_POLL_MS = 750;

export class SlskdError extends Error {
  readonly status: number;
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

export interface SlskdFile {
  readonly filename: string;
  readonly size: number;
  readonly extension?: string;
  readonly bitRate?: number;
  readonly bitDepth?: number;
  readonly sampleRate?: number;
  readonly length?: number;
  readonly isVariableBitRate?: boolean;
}

export interface SlskdSearchResponse {
  readonly username: string;
  readonly hasFreeUploadSlot: boolean;
  readonly queueLength: number;
  readonly uploadSpeed: number;
  readonly fileCount: number;
  readonly lockedFileCount: number;
  readonly files: readonly SlskdFile[];
  readonly lockedFiles: readonly SlskdFile[];
}

export interface SlskdSearch {
  readonly id: string;
  readonly searchText: string;
  readonly token: number;
  readonly state: string;
  readonly fileCount: number;
  readonly lockedFileCount: number;
  readonly responseCount: number;
  readonly startedAt?: string;
  readonly endedAt?: string;
  readonly responses?: readonly SlskdSearchResponse[];
}

export interface SlskdSearchOptions {
  readonly id?: string;
  readonly fileLimit?: number;
  readonly responseLimit?: number;
  readonly minimumResponseFileCount?: number;
  readonly minimumPeerUploadSpeed?: number;
  readonly maximumPeerQueueLength?: number;
  readonly searchTimeout?: number;
}

export interface SlskdSearchResult {
  readonly search: SlskdSearch;
  readonly responses: readonly SlskdSearchResponse[];
  readonly timedOut: boolean;
}

export interface SlskdTransfer {
  readonly id: string;
  readonly username: string;
  readonly direction: "Download" | "Upload";
  readonly filename: string;
  readonly size: number;
  readonly state: string;
  readonly bytesTransferred: number;
  readonly bytesRemaining: number;
  readonly percentComplete: number;
  readonly averageSpeed: number;
  readonly enqueuedAt?: string;
  readonly startedAt?: string;
  readonly endedAt?: string;
  readonly exception?: string;
}

export interface SlskdTransferDirectory {
  readonly directory: string;
  readonly fileCount: number;
  readonly files: readonly SlskdTransfer[];
}

export interface SlskdUserTransfers {
  readonly username: string;
  readonly directories: readonly SlskdTransferDirectory[];
}

export interface SlskdDownloadRequest {
  readonly filename: string;
  readonly size: number;
}

export interface SlskdCandidate {
  readonly username: string;
  readonly files: readonly SlskdDownloadRequest[];
}

export interface SlskdRejection {
  readonly username: string;
  readonly reason: string;
}

export interface SlskdEnqueueResult {
  readonly username: string;
  readonly fileCount: number;
  readonly rejected: readonly SlskdRejection[];
}

export interface SlskdApplicationState {
  readonly version: string;
  readonly server: {
    readonly address: string;
    readonly state: string;
    readonly username?: string;
  };
}

export interface SlskdClientOptions {
  readonly baseUrl: string;
  readonly apiKey: string;
  readonly timeoutMs?: number;
}

export class SlskdClient {
  static isConfigured(): boolean {
    return config.slskdUrl !== null && config.slskdApiKey !== null;
  }

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

  static isSearchComplete(state: string): boolean {
    return state.startsWith("Completed");
  }

  static isTransferComplete(state: string): boolean {
    return state.startsWith("Completed");
  }

  static isTransferUnderway(transfer: SlskdTransfer): boolean {
    return transfer.state === "InProgress" || transfer.bytesTransferred > 0;
  }

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

  get baseUrl(): string {
    return this.#baseUrl;
  }

  applicationState(): Promise<SlskdApplicationState> {
    return this.#json("GET", "/application");
  }

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

  async deleteSearch(id: string): Promise<void> {
    await this.#send("DELETE", `/searches/${encodeURIComponent(id)}`);
  }

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
        await this.deleteSearch(created.id).catch((error: unknown) => {
          console.warn(`Could not delete slskd search ${created.id}:`, error);
        });
      }
    }
  }

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

      if (mine.length > 0 && failed.length === mine.length) {
        const first = failed[0];
        return first?.exception ?? first?.state ?? "the peer refused it";
      }

      if (mine.some(SlskdClient.isTransferUnderway)) return undefined;

      if (Date.now() >= deadline) {
        if (mine.length > failed.length) return undefined;
        return everListed
          ? "every file was refused"
          : "slskd never listed the transfer";
      }

      await SlskdClient.#delay(VERIFY_POLL_MS);
    }
  }

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

  async #transfersFor(username: string): Promise<readonly SlskdTransfer[]> {
    try {
      const user = await this.downloadsFor(username);
      return user.directories.flatMap((directory) => directory.files);
    } catch (error) {
      if (error instanceof SlskdError && error.status === 404) return [];
      throw error;
    }
  }

  downloads(): Promise<readonly SlskdUserTransfers[]> {
    return this.#json("GET", "/transfers/downloads");
  }

  downloadsFor(username: string): Promise<SlskdUserTransfers> {
    return this.#json(
      "GET",
      `/transfers/downloads/${encodeURIComponent(username)}`,
    );
  }

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
      throw new SlskdError(
        `${method} ${path} could not reach slskd at ${this.#baseUrl}.`,
        { cause },
      );
    }

    if (!response.ok) {
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
