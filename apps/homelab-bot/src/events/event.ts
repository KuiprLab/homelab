import type { Awaitable, ClientEvents } from "discord.js";

export interface Event<K extends keyof ClientEvents = keyof ClientEvents> {
  readonly name: K;
  readonly execute: (...args: ClientEvents[K]) => Awaitable<void>;
}
